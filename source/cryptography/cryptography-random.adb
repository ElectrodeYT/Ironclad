--  cryptography-random.adb: The random number generator of the kernel.
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

with Ada.Unchecked_Conversion;
with Memory.Physical; use Memory.Physical;
with Arch.Snippets;
with Memory; use Memory;
with Cryptography.Chacha20;

package body Cryptography.Random is
   --  The core of our RNG is Chacha20-based. We just create a keystream with a
   --  random key, nonce, and block id. The key is randomized each
   --  invocation, the nonce is randomized each block, block id is incremental.
   --  As long as the key and nonce remain secret, future key streams should
   --  not be predictable.
   --  TODO: Please, more entropy!

   --  Unit passes GNATprove AoRTE, GNAT does not know this.
   pragma Suppress (All_Checks);

   procedure Fill_Data (Data : out Crypto_Data) is
      type Seed is record
         Seed1 : MD5.MD5_Hash;
         Seed2 : MD5.MD5_Hash;
      end record with Size => 256;
      function To_Seed is new Ada.Unchecked_Conversion (Seed, Chacha20.Key);

      --  Seed every time a new chain of random numbers is requested.
      S : constant Seed := (Seed1 => Get_Seed, Seed2 => Get_Seed);
      Temp        : Unsigned_64;
      Cha_Block   : Chacha20.Block := (others => 0);
      Index       : Natural     := Cha_Block'Last + 1;
      Block_Index : Unsigned_64 := 0;
   begin
      for Value of Data loop
         if Index > Cha_Block'Last then
            Temp        := Arch.Snippets.Read_Cycles;
            Cha_Block   := Chacha20.Gen_Key (To_Seed (S), Temp, Block_Index);
            Index       := Cha_Block'First;
            Block_Index := Block_Index + 1;
         end if;

         Value := Unsigned_8 (Cha_Block (Index) and 16#FF#);
         Index := Index + 1;
      end loop;
   end Fill_Data;

   function Get_Integer return Unsigned_64 is
      Data : Crypto_Data (1 .. 8);
   begin
      Fill_Data (Data);
      return Shift_Left (Unsigned_64 (Data (1)), 56) or
             Shift_Left (Unsigned_64 (Data (2)), 48) or
             Shift_Left (Unsigned_64 (Data (3)), 40) or
             Shift_Left (Unsigned_64 (Data (4)), 32) or
             Shift_Left (Unsigned_64 (Data (5)), 24) or
             Shift_Left (Unsigned_64 (Data (6)), 16) or
             Shift_Left (Unsigned_64 (Data (7)),  8) or
             Shift_Left (Unsigned_64 (Data (8)),  0);
   end Get_Integer;

   function Get_Integer (Min, Max : Unsigned_64) return Unsigned_64 is
   begin
      return (Get_Integer mod (Max + 1 - Min)) + Min;
   end Get_Integer;

   function Get_Seed return MD5.MD5_Hash is
      Cycles  : Unsigned_64;
      Used    : Unsigned_64;
      Stats   : Memory.Physical.Statistics;
      To_Hash : MD5.MD5_Blocks (1 .. 1);
   begin
      Get_Statistics (Stats);
      Cycles  := Arch.Snippets.Read_Cycles;
      Used    := Unsigned_64 (Stats.Available - Stats.Free);
      To_Hash := (0 => (
         0  => Unsigned_32 (Shift_Right (Cycles, 32) and 16#FFFFFFFF#),
         1  => Unsigned_32 (Cycles                   and 16#FFFFFFFF#),
         2  => Unsigned_32 (Shift_Right (Used, 32)   and 16#FFFFFFFF#),
         3  => Unsigned_32 (Used                     and 16#FFFFFFFF#),
         14 => 128,
         others => 0
      ));
      return MD5.Digest (To_Hash);
   end Get_Seed;
end Cryptography.Random;
