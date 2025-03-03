--  devices-rtl8139.ads: RTL8139 driver.
--  Copyright (C) 2025 Alexander Richards
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

with System.Storage_Elements; use System.Storage_Elements;
with Arch.PCI;
with Arch.MMU;
with Lib.Messages;
with Memory.Physical;
with Lib.Alignment;
with Arch.Snippets;
with Scheduler;

package body Devices.RTL8139 with SPARK_Mode => Off is
   package A is new Lib.Alignment (Unsigned_64);

   function Init return Boolean is
      PCI_Dev : Arch.PCI.PCI_Device;
      PCI_Bar : Arch.PCI.Base_Address_Register;

      Success : Boolean;

      Receive_Buffer_Start : Memory.Virtual_Address;

      IO_Base : Unsigned_16;
      CD : Controller_Data_Acc;

      Temp_Bool : Boolean;
   begin
      Lib.Messages.Put_Line ("Init RTL8139");

      for Idx in 1 .. Arch.PCI.Enumerate_Devices (
         Vendor_ID => 16#10EC#,
         Device_ID => 16#8139#
      ) loop
         Lib.Messages.Put_Line ("Init RTL8139 Idx " & Integer'Image (Idx));

         Arch.PCI.Search_Device
            (Vendor_ID => 16#10EC#,
             Device_ID => 16#8139#,
             Idx => Idx,
             Result => PCI_Dev,
             Success => Success);
         if not Success then
            return True;
         end if;

         Arch.PCI.Get_BAR (PCI_Dev, 0, PCI_Bar, Success);
         Arch.PCI.Enable_Bus_Mastering (PCI_Dev);

         Memory.Physical.Lower_Half_Alloc
          (Addr => Receive_Buffer_Start,
           --  The Receive buffer needs to be a bit bigger than 8192,
           --  as the RTL8139 has a tendency to write past buffers
           Size => A.Align_Up (8192 + 16, Arch.MMU.Page_Size),
           Success => Success);

         if not Success then
            Lib.Messages.Put_Line ("Failed to allocate receive buffer; "
            & "got addr=" & Memory.Virtual_Address'Image
             (Receive_Buffer_Start));
            return False;
         end if;

         if PCI_Bar.Base > Memory.Virtual_Address (Unsigned_16'Last) then
            Lib.Messages.Put_Line ("IO Base out of range");
            return False;
         end if;

         --  Really ugly code to convert the PCI Bar to a port IO offset
         IO_Base := Unsigned_16 (To_Integer (To_Address (PCI_Bar.Base)));

         CD := new Controller_Data'
          (Receive_Buffer_Start => Receive_Buffer_Start,
           IO_Base => IO_Base);

         --  Power on the NIC
         Put_IO_8 (CD, REG_CONFIG_1, 0);

         --  Reset the NIC
         Put_IO_8 (CD, REG_CMD, 16#10#);

         while (Get_IO_8 (CD, REG_CMD) and 16#10#) /= 0 loop
            Scheduler.Yield_If_Able;
         end loop;

         Success := Set_Receive_Buffer (CD);
         if not Success then
            Lib.Messages.Put_Line ("Failed to set receive buffer");
            return False;
         end if;


         Lib.Messages.Put_Line ("Enumerated RTL8139, IO Base at "
          & Unsigned_16'Image (CD.IO_Base));
      end loop;

      return True;
   exception
      when Constraint_Error =>
         return False;
   end Init;

   function Set_Receive_Buffer (CD : Controller_Data_Acc) return Boolean
   is
   begin
      Put_IO_32 (CD, REG_RBSTART, Unsigned_32
       (CD.Receive_Buffer_Start - Memory.Memory_Offset));
      return True;
   exception
      when Constraint_Error =>
         Lib.Messages.Put_Line ("Constraint_Error when setting receive "
          & "buffers");
         return False;
   end Set_Receive_Buffer;

   procedure Put_IO_8
      (CD     : Controller_Data_Acc;
       Offset : Unsigned_8;
       Value  : Unsigned_8)
   is
   begin
      --  TODO: not x86_64
      Arch.Snippets.Port_Out
       (Port  => CD.IO_Base + Unsigned_16 (Offset),
        Value => Value);
   exception
      when Constraint_Error =>
         Lib.Messages.Put_Line ("Constraint_Error in Put_IO_8");
   end Put_IO_8;

   procedure Put_IO_32
      (CD     : Controller_Data_Acc;
       Offset : Unsigned_8;
       Value  : Unsigned_32)
   is
   begin
      --  TODO: not x86_64
      Arch.Snippets.Port_Out32
       (Port  => CD.IO_Base + Unsigned_16 (Offset),
        Value => Value);
   exception
      when Constraint_Error =>
         Lib.Messages.Put_Line ("Constraint_Error in Put_IO_32");
   end Put_IO_32;

   function Get_IO_8
      (CD     : Controller_Data_Acc;
       Offset : Unsigned_8) return Unsigned_8
   is
   begin
      --  TODO: not x86_64
      return Arch.Snippets.Port_In (CD.IO_Base + Unsigned_16 (Offset));
   exception
      when Constraint_Error =>
         Lib.Messages.Put_Line ("Constraint_Error in Get_IO_8");
         return 0;
   end Get_IO_8;

end Devices.RTL8139;