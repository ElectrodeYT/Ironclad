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

with Memory;

package Devices.RTL8139 with SPARK_Mode => Off is
   function Init return Boolean;

private
   type Controller_Data is record
      Receive_Buffer_Start : Memory.Virtual_Address;
      IO_Base : Unsigned_16;
   end record;
   type Controller_Data_Acc is access all Controller_Data;

   REG_RBSTART  : constant := 16#30#;
   REG_CMD      : constant := 16#37#;
   REG_CONFIG_1 : constant := 16#52#;

   procedure Put_IO_8
      (CD     : Controller_Data_Acc;
       Offset : Unsigned_8;
       Value   : Unsigned_8);

   procedure Put_IO_32
      (CD     : Controller_Data_Acc;
       Offset : Unsigned_8;
       Value  : Unsigned_32);

   function Get_IO_8
      (CD     : Controller_Data_Acc;
       Offset : Unsigned_8) return Unsigned_8;

   function Set_Receive_Buffer (CD : Controller_Data_Acc) return Boolean;

end Devices.RTL8139;