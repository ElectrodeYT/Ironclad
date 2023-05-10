--  vfs.adb: FS and register dispatching.
--  Copyright (C) 2023 streaksu
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

with VFS.EXT;
with VFS.FAT;
with VFS.QNX;
with Ada.Characters.Latin_1;

package body VFS with SPARK_Mode => Off is
   procedure Init is
   begin
      Mounts := new Mount_Registry'(others =>
         (Mounted_Dev => Devices.Error_Handle,
          Mounted_FS  => FS_EXT,
          FS_Data     => System.Null_Address,
          Path_Length => 0,
          Path_Buffer => (others => ' ')));
      Mounts_Mutex := Lib.Synchronization.Unlocked_Semaphore;
   end Init;

   function Mount
      (Device_Name  : String;
       Mount_Path   : String;
       Do_Read_Only : Boolean) return Boolean
   is
   begin
      return Mount (Device_Name, Mount_Path, FS_EXT, Do_Read_Only) or else
             Mount (Device_Name, Mount_Path, FS_FAT, Do_Read_Only);
   end Mount;

   function Mount
      (Device_Name  : String;
       Mount_Path   : String;
       FS           : FS_Type;
       Do_Read_Only : Boolean) return Boolean
   is
      Dev     : constant Device_Handle := Devices.Fetch (Device_Name);
      FS_Data : System.Address         := System.Null_Address;
      Free_I  : FS_Handle              := VFS.Error_Handle;
   begin
      if not Is_Absolute (Mount_Path)           or
         Mount_Path'Length > Path_Buffer_Length or
         Dev = Devices.Error_Handle
      then
         return False;
      end if;

      Lib.Synchronization.Seize (Mounts_Mutex);
      for I in Mounts'Range loop
         if Mounts (I).Mounted_Dev = Dev then
            Free_I := VFS.Error_Handle;
            goto Return_End;
         elsif Mounts (I).Mounted_Dev = Devices.Error_Handle then
            Free_I := I;
         end if;
      end loop;
      if Free_I = VFS.Error_Handle then
         goto Return_End;
      end if;

      case FS is
         when FS_EXT =>
            FS_Data := VFS.EXT.Probe (Dev, Do_Read_Only);
            Mounts (Free_I).Mounted_FS := FS_EXT;
         when FS_FAT =>
            FS_Data := VFS.FAT.Probe (Dev, Do_Read_Only);
            Mounts (Free_I).Mounted_FS := FS_FAT;
         when FS_QNX =>
            FS_Data := VFS.QNX.Probe (Dev, Do_Read_Only);
            Mounts (Free_I).Mounted_FS := FS_QNX;
      end case;

      if FS_Data /= System.Null_Address then
         Mounts (Free_I).FS_Data := FS_Data;
         Mounts (Free_I).Mounted_Dev := Dev;
         Mounts (Free_I).Path_Length := Mount_Path'Length;
         Mounts (Free_I).Path_Buffer (1 .. Mount_Path'Length) := Mount_Path;
      else
         Free_I := VFS.Error_Handle;
      end if;

   <<Return_End>>
      Lib.Synchronization.Release (Mounts_Mutex);
      return Free_I /= VFS.Error_Handle;
   end Mount;

   function Unmount (Path : String; Force : Boolean) return Boolean is
      Success : Boolean := False;
   begin
      Lib.Synchronization.Seize (Mounts_Mutex);
      for I in Mounts'Range loop
         if Mounts (I).Mounted_Dev /= Devices.Error_Handle and then
            Mounts (I).Path_Buffer (1 .. Mounts (I).Path_Length) = Path
         then
            case Mounts (I).Mounted_FS is
               when FS_EXT => EXT.Unmount (Mounts (I).FS_Data);
               when FS_FAT => FAT.Unmount (Mounts (I).FS_Data);
               when FS_QNX => QNX.Unmount (Mounts (I).FS_Data);
            end case;

            if Force or Mounts (I).FS_Data = Null_Address then
               Mounts (I).Mounted_Dev := Devices.Error_Handle;
               Success := True;
            end if;
            goto Return_End;
         end if;
      end loop;
   <<Return_End>>
      Lib.Synchronization.Release (Mounts_Mutex);
      return Success;
   end Unmount;

   procedure Get_Mount
      (Path   : String;
       Match  : out Natural;
       Handle : out FS_Handle)
   is
   begin
      Match  := 0;
      Handle := VFS.Error_Handle;

      Lib.Synchronization.Seize (Mounts_Mutex);
      for I in Mounts'Range loop
         if Mounts (I).Mounted_Dev /= Devices.Error_Handle and then
            Path'Length >= Mounts (I).Path_Length          and then
            Match < Mounts (I).Path_Length                 and then
            Mounts (I).Path_Buffer (1 .. Mounts (I).Path_Length) =
            Path (Path'First .. Path'First + Mounts (I).Path_Length - 1)
         then
            Handle := I;
            Match  := Mounts (I).Path_Length;
         end if;
      end loop;
      Lib.Synchronization.Release (Mounts_Mutex);

      if Match > 1           and then
         Path'Length > Match and then
         Path (Path'First + Match) = '/'
      then
         Match := Match + 1;
      end if;
   end Get_Mount;

   procedure List_All (List : out Mountpoint_Info_Arr; Total : out Natural) is
      Curr_Index        : Natural := 0;
      Dev_Name          : String (1 .. Devices.Max_Name_Length);
      Dev_Len, Path_Len : Natural;
   begin
      Total := 0;

      Lib.Synchronization.Seize (Mounts_Mutex);
      for I in Mounts'Range loop
         if Mounts (I).Mounted_Dev /= Devices.Error_Handle then
            Total := Total + 1;
            if Curr_Index < List'Length then
               Devices.Fetch_Name (Mounts (I).Mounted_Dev, Dev_Name, Dev_Len);
               Path_Len := Mounts (I).Path_Length;

               List (List'First + Curr_Index) :=
                  (Inner_Type => Mounts (I).Mounted_FS,
                   Source     => Dev_Name (1 .. 20),
                   Source_Len => Dev_Len,
                   Location   => Mounts (I).Path_Buffer (1 .. Path_Len) &
                            (Path_Len + 1 .. 20 => Ada.Characters.Latin_1.NUL),
                   Location_Len => Path_Len);
               Curr_Index := Curr_Index + 1;
            end if;
         end if;
      end loop;
      Lib.Synchronization.Release (Mounts_Mutex);
   end List_All;

   function Get_Backing_FS (Key : FS_Handle) return FS_Type is
   begin
      return Mounts (Key).Mounted_FS;
   end Get_Backing_FS;

   function Get_Backing_FS_Data (Key : FS_Handle) return System.Address is
   begin
      return Mounts (Key).FS_Data;
   end Get_Backing_FS_Data;

   function Get_Backing_Device (Key : FS_Handle) return Device_Handle is
   begin
      return Mounts (Key).Mounted_Dev;
   end Get_Backing_Device;
   ----------------------------------------------------------------------------
   procedure Open
      (Key     : FS_Handle;
       Path    : String;
       Ino     : out File_Inode_Number;
       Success : out FS_Status)
   is
   begin
      case Mounts (Key).Mounted_FS is
         when FS_EXT =>
            EXT.Open
               (FS      => Mounts (Key).FS_Data,
                Path    => Path,
                Ino     => Ino,
                Success => Success);
         when FS_FAT =>
            FAT.Open
               (FS      => Mounts (Key).FS_Data,
                Path    => Path,
                Ino     => Ino,
                Success => Success);
         when FS_QNX =>
            Ino     := 0;
            Success := FS_Not_Supported;
      end case;
   end Open;

   function Create_Node
      (Key  : FS_Handle;
       Path : String;
       Typ  : File_Type;
       Mode : File_Mode) return FS_Status
   is
   begin
      case Mounts (Key).Mounted_FS is
         when FS_EXT =>
            return EXT.Create_Node (Mounts (Key).FS_Data, Path, Typ, Mode);
         when others =>
            return FS_Not_Supported;
      end case;
   end Create_Node;

   function Create_Symbolic_Link
      (Key          : FS_Handle;
       Path, Target : String;
       Mode         : Unsigned_32) return FS_Status
   is
   begin
      case Mounts (Key).Mounted_FS is
         when FS_EXT =>
            return EXT.Create_Symbolic_Link
               (Mounts (Key).FS_Data, Path, Target, Mode);
         when others =>
            return FS_Not_Supported;
      end case;
   end Create_Symbolic_Link;

   function Create_Hard_Link
      (Key          : FS_Handle;
       Path, Target : String) return FS_Status
   is
   begin
      case Mounts (Key).Mounted_FS is
         when FS_EXT =>
            return EXT.Create_Hard_Link (Mounts (Key).FS_Data, Path, Target);
         when others =>
            return FS_Not_Supported;
      end case;
   end Create_Hard_Link;

   function Rename
      (Key    : FS_Handle;
       Source : String;
       Target : String;
       Keep   : Boolean) return FS_Status
   is
   begin
      case Mounts (Key).Mounted_FS is
         when FS_EXT =>
            return EXT.Rename (Mounts (Key).FS_Data, Source, Target, Keep);
         when others =>
            return FS_Not_Supported;
      end case;
   end Rename;

   function Unlink (Key : FS_Handle; Path : String) return FS_Status is
   begin
      case Mounts (Key).Mounted_FS is
         when FS_EXT => return EXT.Unlink (Mounts (Key).FS_Data, Path);
         when others => return FS_Not_Supported;
      end case;
   end Unlink;

   procedure Close (Key : FS_Handle; Ino : File_Inode_Number) is
   begin
      case Mounts (Key).Mounted_FS is
         when FS_EXT => EXT.Close (Mounts (Key).FS_Data, Ino);
         when FS_FAT => FAT.Close (Mounts (Key).FS_Data, Ino);
         when FS_QNX => null;
      end case;
   end Close;

   procedure Read_Entries
      (Key       : FS_Handle;
       Ino       : File_Inode_Number;
       Entities  : out Directory_Entities;
       Ret_Count : out Natural;
       Success   : out FS_Status)
   is
   begin
      case Mounts (Key).Mounted_FS is
         when FS_EXT =>
            EXT.Read_Entries
               (Mounts (Key).FS_Data,
                Ino,
                Entities,
                Ret_Count,
                Success);
         when FS_FAT =>
            FAT.Read_Entries
               (Mounts (Key).FS_Data,
                Ino,
                Entities,
                Ret_Count,
                Success);
         when FS_QNX =>
            Ret_Count := 0;
            Success   := FS_Not_Supported;
      end case;
   end Read_Entries;

   procedure Read_Symbolic_Link
      (Key       : FS_Handle;
       Ino       : File_Inode_Number;
       Path      : out String;
       Ret_Count : out Natural)
   is
   begin
      case Mounts (Key).Mounted_FS is
         when FS_EXT =>
            EXT.Read_Symbolic_Link
               (Mounts (Key).FS_Data, Ino, Path, Ret_Count);
         when FS_FAT =>
            Path      := (others => ' ');
            Ret_Count := 0;
         when FS_QNX =>
            Path      := (others => ' ');
            Ret_Count := 0;
      end case;
   end Read_Symbolic_Link;

   procedure Read
      (Key       : FS_Handle;
       Ino       : File_Inode_Number;
       Offset    : Unsigned_64;
       Data      : out Operation_Data;
       Ret_Count : out Natural;
       Success   : out FS_Status)
   is
   begin
      case Mounts (Key).Mounted_FS is
         when FS_EXT =>
            EXT.Read
               (Mounts (Key).FS_Data,
                Ino,
                Offset,
                Data,
                Ret_Count,
                Success);
         when FS_FAT =>
            FAT.Read
               (Mounts (Key).FS_Data,
                Ino,
                Offset,
                Data,
                Ret_Count,
                Success);
         when FS_QNX =>
            Ret_Count := 0;
            Success   := FS_Not_Supported;
      end case;
   end Read;

   procedure Write
      (Key       : FS_Handle;
       Ino       : File_Inode_Number;
       Offset    : Unsigned_64;
       Data      : Operation_Data;
       Ret_Count : out Natural;
       Success   : out FS_Status)
   is
   begin
      case Mounts (Key).Mounted_FS is
         when FS_EXT =>
            EXT.Write
               (Mounts (Key).FS_Data,
                Ino,
                Offset,
                Data,
                Ret_Count,
                Success);
         when others =>
            Ret_Count := 0;
            Success   := FS_Not_Supported;
      end case;
   end Write;

   procedure Stat
      (Key      : FS_Handle;
       Ino      : File_Inode_Number;
       Stat_Val : out File_Stat;
       Success  : out FS_Status)
   is
   begin
      case Mounts (Key).Mounted_FS is
         when FS_EXT =>
            Success := EXT.Stat (Mounts (Key).FS_Data, Ino, Stat_Val);
         when FS_FAT =>
            Success := FAT.Stat (Mounts (Key).FS_Data, Ino, Stat_Val);
         when FS_QNX =>
            Success := FS_Not_Supported;
      end case;
   end Stat;

   function Truncate
      (Key      : FS_Handle;
       Ino      : File_Inode_Number;
       New_Size : Unsigned_64) return FS_Status
   is
   begin
      case Mounts (Key).Mounted_FS is
         when FS_EXT =>
            return EXT.Truncate (Mounts (Key).FS_Data, Ino, New_Size);
         when others =>
            return FS_Not_Supported;
      end case;
   end Truncate;

   function IO_Control
      (Key     : FS_Handle;
       Ino     : File_Inode_Number;
       Request : Unsigned_64;
       Arg     : System.Address) return FS_Status
   is
   begin
      case Mounts (Key).Mounted_FS is
         when FS_EXT =>
            return EXT.IO_Control (Mounts (Key).FS_Data, Ino, Request, Arg);
         when others =>
            return FS_Not_Supported;
      end case;
   end IO_Control;

   function Synchronize return Boolean is
      Final_Success : Boolean := True;
   begin
      Lib.Synchronization.Seize (Mounts_Mutex);
      for I in Mounts'Range loop
         if Mounts (I).Mounted_Dev /= Devices.Error_Handle then
            if Synchronize (I) = FS_IO_Failure then
               Final_Success := False;
            end if;
         end if;
      end loop;
      Lib.Synchronization.Release (Mounts_Mutex);
      return Final_Success;
   end Synchronize;

   function Synchronize (Key : FS_Handle) return FS_Status is
   begin
      case Mounts (Key).Mounted_FS is
         when FS_EXT => return EXT.Synchronize (Mounts (Key).FS_Data);
         when others => return FS_Not_Supported;
      end case;
   end Synchronize;

   function Synchronize
      (Key : FS_Handle;
       Ino : File_Inode_Number) return FS_Status
   is
   begin
      case Mounts (Key).Mounted_FS is
         when FS_EXT => return EXT.Synchronize (Mounts (Key).FS_Data, Ino);
         when others => return FS_Not_Supported;
      end case;
   end Synchronize;
   ----------------------------------------------------------------------------
   function Is_Absolute (Path : String) return Boolean is
   begin
      return Path'Length >= 1 and then Path (Path'First) = '/';
   end Is_Absolute;

   function Is_Canonical (Path : String) return Boolean is
      Previous : Character := ' ';
   begin
      if not Is_Absolute (Path) or else
         (Path'Length > 1 and Path (Path'Last) = '/')
      then
         return False;
      end if;

      for C of Path loop
         if Previous = '/' and C = '/' then
            return False;
         end if;
         Previous := C;
      end loop;

      return True;
   end Is_Canonical;

   procedure Compound_Path
      (Base      : String;
       Extension : String;
       Result    : out String;
       Count     : out Natural)
   is
      Curr_Index :   Natural;
      Previous   : Character;
   begin
      --  Actually compound the paths.
      if Is_Absolute (Extension) and Result'Length >= Extension'Length then
         Count := Extension'Length;
         Result (Result'First .. Result'First - 1 + Count) := Extension;
      elsif Result'Length >= Base'Length + Extension'Length + 1 then
         Count := Base'Length + Extension'Length + 1;
         Result (Result'First .. Result'First - 1 + Count) :=
            Base & "/" & Extension;
      else
         Count := 0;
         return;
      end if;

      --  Clean the path.
      Curr_Index := Result'First;
      Previous   := ' ';
      loop
         if Previous = '/' and Result (Curr_Index) = '/' then
            Result (Curr_Index - 1 .. Result'First - 2 + Count) :=
               Result (Curr_Index .. Result'First - 1 + Count);
            Count := Count - 1;
         else
            Curr_Index := Curr_Index + 1;
         end if;
         if Curr_Index = Result'First + Count + 1 then
            exit;
         else
            Previous := Result (Curr_Index - 1);
         end if;
      end loop;

      if Count > 1 and then Result (Result'First - 1 + Count) = '/' then
         Count := Count - 1;
      end if;
   end Compound_Path;
end VFS;
