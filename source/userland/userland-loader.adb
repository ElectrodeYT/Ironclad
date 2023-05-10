--  userland-loader.adb: Program loader.
--  Copyright (C) 2021 streaksu
--
--  This program is free software: you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation, either version 3 of the License, or
--  (at your option) any later version.
--
--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with this program.  If not, see <http://www.gnu.org/licenses/>.

with Ada.Characters.Latin_1;
with Interfaces; use Interfaces;
with System;
with System.Storage_Elements; use System.Storage_Elements;
with Memory.Virtual;
with Memory; use Memory;
with Userland.ELF;
with Scheduler; use Scheduler;
with Ada.Unchecked_Conversion;
with Userland.Memory_Locations;
with Lib.Alignment;
with Cryptography.Random;

package body Userland.Loader with SPARK_Mode => Off is
   function Start_Program
      (FD          : File_Acc;
       Arguments   : Argument_Arr;
       Environment : Environment_Arr;
       StdIn_Path  : String;
       StdOut_Path : String;
       StdErr_Path : String) return PID
   is
      Returned_PID : constant PID := Process.Create_Process;
      Discard      : Natural;
      Stdin, StdOut, StdErr                : File_Acc;
      User_Stdin, User_StdOut, User_StdErr : File_Description_Acc;
   begin
      Open (StdIn_Path,  Read_Only, Stdin);
      Open (StdOut_Path, Write_Only, StdOut);
      Open (StdErr_Path, Write_Only, StdErr);

      if Returned_PID = Error_PID then
         goto Error;
      end if;
      Process.Set_Common_Map (Returned_PID, Memory.Virtual.New_Map);
      if not Start_Program (FD, Arguments, Environment, Returned_PID) or
         Stdin = null or StdOut = null or StdErr = null
      then
         goto Error_Process;
      end if;

      User_Stdin := new File_Description'(
         Close_On_Exec => False,
         Description   => Description_File,
         Inner_File    => Stdin
      );
      User_StdOut := new File_Description'(
         Close_On_Exec => False,
         Description   => Description_File,
         Inner_File    => StdOut
      );
      User_StdErr := new File_Description'(
         Close_On_Exec => False,
         Description   => Description_File,
         Inner_File    => StdErr
      );

      if not Process.Add_File (Returned_PID, User_Stdin,  Discard) or else
         not Process.Add_File (Returned_PID, User_StdOut, Discard) or else
         not Process.Add_File (Returned_PID, User_StdErr, Discard)
      then
         goto Error_Process;
      end if;
      return Returned_PID;

   <<Error_Process>>
      Process.Delete_Process (Returned_PID);
   <<Error>>
      return Error_PID;
   end Start_Program;

   function Start_Program
      (FD          : File_Acc;
       Arguments   : Argument_Arr;
       Environment : Environment_Arr;
       Proc        : PID) return Boolean
   is
      Discard : Boolean;
   begin
      if Start_ELF (FD, Arguments, Environment, Proc) then
         return True;
      end if;
      Set_Position (FD, 0, Discard);
      if Start_Shebang (FD, Arguments, Environment, Proc) then
         return True;
      end if;

      return False;
   end Start_Program;

   function Start_ELF
      (FD          : File_Acc;
       Arguments   : Argument_Arr;
       Environment : Environment_Arr;
       Proc        : PID) return Boolean
   is
      package Aln is new Lib.Alignment (Unsigned_64);

      Loaded_ELF, LD_ELF : ELF.Parsed_ELF;
      Entrypoint   : Virtual_Address;
      LD_Slide : Unsigned_64;
      LD_Path  : String (1 .. 100);
      LD_File  : File_Acc;
   begin
      --  Load the executable.
      Loaded_ELF := ELF.Load_ELF (FD, Process.Get_Common_Map (Proc),
         Memory_Locations.Program_Offset);
      if not Loaded_ELF.Was_Loaded then
         goto Error;
      end if;

      if Loaded_ELF.Linker_Path /= null then
         --  Interpreter paths are relative, so we build an absolute one on
         --  the spot using Path, which is absolute.
         LD_Path (9 .. Loaded_ELF.Linker_Path.all'Length + 8) :=
            Loaded_ELF.Linker_Path (1 .. Loaded_ELF.Linker_Path.all'Length);
         Open (LD_Path (9 .. 7 + Loaded_ELF.Linker_Path.all'Length), Read_Only,
               LD_File);
         if LD_File = null then
            goto Error;
         end if;
         LD_Slide := Cryptography.Random.Get_Integer
            (Memory_Locations.LD_Offset_Min,
             Memory_Locations.LD_Offset_Max);
         LD_Slide := Aln.Align_Up (LD_Slide, Memory.Virtual.Page_Size);
         LD_ELF := ELF.Load_ELF (LD_File, Process.Get_Common_Map (Proc),
                                 LD_Slide);
         Entrypoint := To_Integer (LD_ELF.Entrypoint);
         if not LD_ELF.Was_Loaded then
            goto Error;
         end if;
         Close (LD_File);
      else
         Entrypoint := To_Integer (Loaded_ELF.Entrypoint);
      end if;

      declare
         Returned_TID : constant Scheduler.TID := Scheduler.Create_User_Thread
            (Address    => Entrypoint,
             Args       => Arguments,
             Env        => Environment,
             Map        => Process.Get_Common_Map (Proc),
             Vector     => Loaded_ELF.Vector,
             Stack_Top  => Process.Get_Stack_Base (Proc),
             PID        => Process.Convert (Proc),
             Exec_Stack => Loaded_ELF.Exec_Stack);
      begin
         --  TODO: Do not hardcode stack size.
         Process.Set_Stack_Base (Proc, Process.Get_Stack_Base (Proc) +
                                 16#200000#);

         if Returned_TID = 0 then
            goto Error;
         end if;

         if not Process.Add_Thread (Proc, Returned_TID) then
            Scheduler.Delete_Thread (Returned_TID);
            goto Error;
         end if;
         return True;
      end;

   <<Error>>
      return False;
   end Start_ELF;

   function Start_Shebang
      (FD          : File_Acc;
       Arguments   : Argument_Arr;
       Environment : Environment_Arr;
       Proc        : PID) return Boolean
   is
      use VFS;
      function Conv is new Ada.Unchecked_Conversion
         (Target => Userland.String_Acc, Source => VFS.File.String_Acc);

      Path_Len  : Natural := 0;
      Arg_Len   : Natural := 0;
      Path      : String (1 .. 100);
      Path_Data : Operation_Data (1 .. 100)
         with Import, Address => Path'Address;
      Arg       : String (1 .. 100);
      Char      : Character;
      Char_Data : Operation_Data (1 .. 1)
         with Import, Address => Char'Address;
      Char_Len  : Natural;
      Success   : VFS.FS_Status;
   begin
      Read (FD, Path_Data (1 .. 2), Path_Len, Success);
      if Success /= VFS.FS_Success or Path_Len /= 2 or Path (1 .. 2) /= "#!"
      then
         return False;
      end if;

      --  Format of a shebang: #!path [arg]newline
      Path_Len := 0;
      loop
         Read (FD, Char_Data, Char_Len, Success);
         if Success /= VFS.FS_Success or Char_Len /= 1 then
            return False;
         end if;
         case Char is
            when ' '                       => exit;
            when Ada.Characters.Latin_1.LF => goto Return_Shebang;
            when others => Path_Len := Path_Len + 1; Path (Path_Len) := Char;
         end case;
      end loop;
      loop
         Read (FD, Char_Data, Char_Len, Success);
         if Success /= VFS.FS_Success or Char_Len /= 1 then
            return False;
         end if;
         case Char is
            when Ada.Characters.Latin_1.LF | ' ' => exit;
            when others => Arg_Len := Arg_Len + 1; Arg (Arg_Len) := Char;
         end case;
      end loop;

   <<Return_Shebang>>
      declare
         Arg_Diff : constant Natural := (if Arg_Len = 0 then 1 else 2);
         New_Args : Argument_Arr (1 .. Arguments'Length + Arg_Diff);
         I        : Positive := 1;
         Banged   : VFS.File.File_Acc;
      begin
         New_Args (I) := new String'(Path (1 .. Path_Len));
         I := I + 1;
         if Arg_Len /= 0 then
            New_Args (I) := new String'(Arg (1 .. Arg_Len));
            I := I + 1;
         end if;
         New_Args (I .. New_Args'Length) := Arguments;
         New_Args (I) := Conv (Get_Path (FD));
         Open (Path (1 .. Path_Len), Read_Only, Banged);
         if Banged = null then
            return False;
         end if;
         return Start_Program (
            Banged,
            New_Args,
            Environment,
            Proc
         );
      end;
   end Start_Shebang;
end Userland.Loader;
