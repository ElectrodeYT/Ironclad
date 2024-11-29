--  lib-synchronization.ads: Specification of the synchronization library.
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

with Interfaces; use Interfaces;

package Lib.Synchronization is
   --  A simple binary semaphore for critical sections only.
   --
   --  Interrupt control is implemented with it, as to improve responsiveness,
   --  having an interrupt happen while holding a lock could add massive
   --  amounts of latency.
   type Binary_Semaphore is private;

   --  Value to initialize semaphores with.
   Unlocked_Semaphore : constant Binary_Semaphore;

   --  Lock a semaphore.
   --  When entering this routine, if interrupts are enabled, they will be
   --  disabled.
   --  @param Lock                      Semaphore to lock.
   --  @param Do_Not_Disable_Interrupts If True, do not disable interrupts.
   procedure Seize
      (Lock : aliased in out Binary_Semaphore;
       Do_Not_Disable_Interrupts : Boolean := False);

   --  Release a semaphore unconditionally. If interrupts were disabled, they
   --  will be reenabled.
   --  @param Lock Semaphore to release.
   procedure Release (Lock : aliased in out Binary_Semaphore);
   ----------------------------------------------------------------------------
   --  A more complex synchronization mechanism for more generic uses.
   --
   --  Mutexes will use the scheduler if available and other utilities to
   --  more effectively use waiting time. Use this to guard resources where
   --  having a bit of latency at the time of entering the critical section
   --  is fine, or where the held resource may take a long time to get out
   --  of the section, so you dont want other threads to wait too much doing
   --  nothing.
   type Mutex is private;

   --  Value to initialize mutexes with.
   Unlocked_Mutex : constant Mutex;

   --  Lock a mutex, and not return until locked.
   --  @param Lock  Mutex to lock.
   procedure Seize (Lock : aliased in out Mutex);

   --  Release a mutex unconditionally.
   --  @param Lock  Mutex to lock.
   procedure Release (Lock : aliased in out Mutex);

private

   type Binary_Semaphore is record
      Is_Locked               : Unsigned_8;
      Were_Interrupts_Enabled : Boolean;
   end record;
   Unlocked_Semaphore : constant Binary_Semaphore := (0, False);
   ----------------------------------------------------------------------------
   type Mutex is record
      Is_Locked : Unsigned_8;
   end record;
   Unlocked_Mutex : constant Mutex := (Is_Locked => 0);
   ----------------------------------------------------------------------------
   function Caller_Address (Depth : Natural) return System.Address;
   pragma Import (Intrinsic, Caller_Address, "__builtin_return_address");
end Lib.Synchronization;
