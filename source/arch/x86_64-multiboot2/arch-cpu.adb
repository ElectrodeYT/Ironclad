--  arch-cpu.adb: CPU management routines.
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

with System.Machine_Code; use System.Machine_Code;
with Arch.APIC;
with Memory; use Memory;
with Arch.ACPI;
with Arch.Multiboot2;
with Arch.MMU;
with Arch.IDT;
with Memory.Virtual;
with Arch.Snippets;

package body Arch.CPU with SPARK_Mode => Off is
   procedure Init_Cores is
      Addr : constant Virtual_Address := ACPI.FindTable (ACPI.MADT_Signature);
      MADT           : ACPI.MADT with Address => To_Address (Addr);
      MADT_Length    : constant Unsigned_32 := MADT.Header.Length;
      Current_Byte   : Unsigned_32          := 0;
      BSP_LAPIC_ID   : constant Unsigned_32 := Get_BSP_LAPIC_ID;
      Index          : Positive;
   begin
      --  Count of how many cores are there.
      Core_Count := 1;
      while (Current_Byte + ((MADT'Size / 8) - 1)) < MADT_Length loop
         declare
            LAPIC : ACPI.MADT_LAPIC with Import, Address =>
               MADT.Entries_Start'Address + Storage_Offset (Current_Byte);
         begin
            case LAPIC.Header.Entry_Type is
               when ACPI.MADT_LAPIC_Type =>
                  if ((LAPIC.Flags and 1) /= 0) xor ((LAPIC.Flags and 2) /= 0)
                  then
                     if Unsigned_32 (LAPIC.LAPIC_ID) /= BSP_LAPIC_ID then
                        Core_Count := Core_Count + 1;
                     end if;
                  end if;
               when others => null;
            end case;
            Current_Byte := Current_Byte + Unsigned_32 (LAPIC.Header.Length);
         end;
      end loop;

      --  Initialize the locals list, and initialize the cores.
      Current_Byte := 0;
      Core_Locals  := new Core_Local_Arr (1 .. Core_Count);
      Init_Common (1, BSP_LAPIC_ID);

      Index := 1;
      while (Current_Byte + ((MADT'Size / 8) - 1)) < MADT_Length loop
         declare
            LAPIC : ACPI.MADT_LAPIC with Import, Address =>
               MADT.Entries_Start'Address + Storage_Offset (Current_Byte);
         begin
            case LAPIC.Header.Entry_Type is
               when ACPI.MADT_LAPIC_Type =>
                  if ((LAPIC.Flags and 1) /= 0) xor ((LAPIC.Flags and 2) /= 0)
                  then
                     if Unsigned_32 (LAPIC.LAPIC_ID) /= BSP_LAPIC_ID then
                        Index := Index + 1;
                        Core_Bootstrap (Index, LAPIC.LAPIC_ID);
                     end if;
                  end if;
               when others => null;
            end case;
            Current_Byte := Current_Byte + Unsigned_32 (LAPIC.Header.Length);
         end;
      end loop;
   end Init_Cores;

   function Get_Local return Core_Local_Acc is
      Locals : Core_Local_Acc;
   begin
      --  XXX: We are making the guarantee this can never be null, which it
      --  can if the scheduler does not swap gs correctly.
      Asm ("mov %%gs:0, %0",
           Outputs  => Core_Local_Acc'Asm_Output ("=a", Locals),
           Volatile => True);
      return Locals;
   end Get_Local;

   procedure Core_Bootstrap (Core_Number : Positive; LAPIC_ID : Unsigned_8) is
      --  Stack of the core.
      type Stack is array (1 .. 32768) of Unsigned_8;
      type Stack_Acc is access Stack;
      New_Stk : constant Stack_Acc := new Stack;
      New_Stk_Top : constant System.Address := New_Stk (New_Stk'Last)'Address;

      --  Trampoline addresses and data.
      type Trampoline_Passed_Info is record
         Page_Map    : Unsigned_32;
         Final_Stack : Unsigned_64;
         Core_Number : Unsigned_64;
         LAPIC_ID    : Unsigned_64;
         Booted_Flag : Unsigned_64;
      end record;
      for Trampoline_Passed_Info use record
         Page_Map    at 0 range   0 ..  31;
         Final_Stack at 0 range  32 ..  95;
         Core_Number at 0 range  96 .. 159;
         LAPIC_ID    at 0 range 160 .. 223;
         Booted_Flag at 0 range 224 .. 287;
      end record;
      for Trampoline_Passed_Info'Size use 288;
      type Tramp_Arr is array (1 .. Multiboot2.Max_Sub_1MiB_Size)
         of Unsigned_8;
      Trampoline_Size : Storage_Count with Import,
         External_Name => "smp_trampoline_size";
      Original_Trampoline : Tramp_Arr with Import,
         External_Name => "smp_trampoline_start";
      Trampoline_Data : Tramp_Arr with Import, Volatile,
         Address => Multiboot2.Sub_1MiB_Region;
      Trampoline_Info : Trampoline_Passed_Info with Import, Volatile,
         Address => Trampoline_Data'Address + Trampoline_Size
                    - (Trampoline_Passed_Info'Size / 8);

      --  Data to use for the startup IPIs.
      Addr : constant Integer_Address :=
         (To_Integer (Trampoline_Data'Address) / 4096) or 16#4600#;
      Pagemap_Addr : constant Integer_Address :=
         To_Integer (MMU.Kernel_Table.all'Address) - Memory.Memory_Offset;
   begin
      --  FIXME: Shouldnt be copied every time, only once is enough.
      Trampoline_Data := Original_Trampoline;
      Trampoline_Info := (
         Page_Map    => Unsigned_32 (Pagemap_Addr),
         Final_Stack => Unsigned_64 (To_Integer (New_Stk_Top)),
         Core_Number => Unsigned_64 (Core_Number),
         LAPIC_ID    => Unsigned_64 (LAPIC_ID),
         Booted_Flag => 0
      );

      APIC.LAPIC_Send_IPI_Raw (Unsigned_32 (LAPIC_ID), 16#4500#);
      Delay_Execution (10000000);
      APIC.LAPIC_Send_IPI_Raw (Unsigned_32 (LAPIC_ID), Unsigned_32 (Addr));
      Delay_Execution (10000000);

      for I in 1 .. 100 loop
         if Trampoline_Info.Booted_Flag = 1 then
            return;
         end if;
         Delay_Execution (10000000);
      end loop;
   end Core_Bootstrap;

   procedure Init_Core (Core_Number : Positive; LAPIC_ID : Unsigned_8) is
      Discard : Boolean;
   begin
      --  Load the global GDT, IDT, mappings, and LAPIC.
      GDT.Load_GDT;
      IDT.Load_IDT;
      Discard := Memory.Virtual.Make_Active (Memory.Virtual.Get_Kernel_Map);
      APIC.Init_LAPIC;

      --  Load several goodies.
      Init_Common (Core_Number, Unsigned_32 (LAPIC_ID));

      --  Send the core to idle, waiting for the scheduler to tell it to do
      --  something, from here, we lose control. Farewell, core.
      Scheduler.Idle_Core;
   end Init_Core;

   procedure Init_Common (Core_Number : Positive; LAPIC : Unsigned_32) is
      PAT_MSR  : constant := 16#00000277#;

      CR0 : Unsigned_64 := Snippets.Read_CR0;
      CR4 : Unsigned_64 := Snippets.Read_CR4;
      PAT : Unsigned_64 := Snippets.Read_MSR (PAT_MSR);

      Locals_Addr : constant Unsigned_64 :=
         Unsigned_64 (To_Integer (Core_Locals (Core_Number)'Address));
   begin
      --  Enable WP and SSE/2.
      CR0 := CR0 or Shift_Left (1, 16);
      CR0 := (CR0 and (not Shift_Left (1, 2))) or Shift_Left (1, 1);
      CR4 := CR4 or Shift_Left (3, 9);

      --  Enable UMIP if present.
      if Supports_UMIP then
         CR4 := CR4 or Shift_Left (1, 11);
      end if;

      --  Initialise the PAT (write-protect / write-combining).
      PAT := PAT and (16#FFFFFFFF#);
      PAT := PAT or  Shift_Left (Unsigned_64 (16#0105#), 32);

      --  Write the final configuration.
      Snippets.Write_CR0 (CR0);
      Snippets.Write_CR4 (CR4);
      Snippets.Write_MSR (PAT_MSR, PAT);

      --  Prepare the core local structure and set it in GS.
      Core_Locals (Core_Number) :=
         (Self            => Core_Locals (Core_Number)'Access,
          Number          => Core_Number,
          LAPIC_ID        => LAPIC,
          LAPIC_Timer_Hz  => APIC.LAPIC_Timer_Calibrate,
          Current_Thread  => 0,
          Current_Process => null,
          others          => <>);
      Snippets.Write_GS        (Locals_Addr);
      Snippets.Write_Kernel_GS (Locals_Addr);

      --  Load the TSS.
      GDT.Load_TSS (Core_Locals (Core_Number).Core_TSS'Address);
   end Init_Common;

   function Supports_UMIP return Boolean is
      EAX, EBX, ECX, EDX : Unsigned_32;
   begin
      Snippets.Get_CPUID (7, 0, EAX, EBX, ECX, EDX);
      return (ECX and 2#100#) /= 0;
   end Supports_UMIP;

   function Get_BSP_LAPIC_ID return Unsigned_32 is
      EAX, EBX, ECX, EDX : Unsigned_32;
   begin
      Snippets.Get_CPUID (1, 0, EAX, EBX, ECX, EDX);
      return Shift_Right (EBX, 24) and 16#FF#;
   end Get_BSP_LAPIC_ID;

   procedure Delay_Execution (Cycles : Unsigned_64) is
      Next_Stop : constant Unsigned_64 := Snippets.Read_Cycles + Cycles;
   begin
      while Snippets.Read_Cycles < Next_Stop loop null; end loop;
   end Delay_Execution;
end Arch.CPU;
