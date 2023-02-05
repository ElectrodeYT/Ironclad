--  vfs.ads: FS and register dispatching.
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

with Interfaces; use Interfaces;
with System;     use System;
with Devices;    use Devices;

package VFS with SPARK_Mode => Off is
   --  Stat structure of a file, which describes the qualities of a file.
   type File_Type is (
      File_Regular,
      File_Directory,
      File_Symbolic_Link,
      File_Character_Device,
      File_Block_Device
   );
   type File_Stat is record
      Unique_Identifier : Unsigned_64;
      Type_Of_File      : File_Type;
      Mode              : Unsigned_32;
      Hard_Link_Count   : Positive;
      Byte_Size         : Unsigned_64;
      IO_Block_Size     : Natural;
      IO_Block_Count    : Unsigned_64;
   end record;

   --  Describes an entity inside the contents of a directory.
   type Directory_Entity is record
      Inode_Number : Unsigned_64;
      Name_Buffer  : String (1 .. 60);
      Name_Len     : Natural;
      Type_Of_File : File_Type;
   end record;
   type Directory_Entities is array (Natural range <>) of Directory_Entity;
   ----------------------------------------------------------------------------
   --  Handle for interfacing with mounted FSs and FS types.
   type FS_Type   is (FS_USTAR, FS_EXT);
   type FS_Handle is private;
   Error_Handle : constant FS_Handle;

   --  Initialize the internal VFS registries.
   procedure Init;

   --  Mount the passed device name into the passed path.
   --  @param Name Name of the device (/dev/<name>).
   --  @param Path Absolute path for mounting.
   --  @param FS FS Type to mount as.
   --  @return True on success, False on failure.
   function Mount (Name, Path : String; FS : FS_Type) return Boolean;

   --  Mount the passed device name into the passed path, guessing the FS.
   --  @param Name Name of the device (/dev/<name>).
   --  @param Path Absolute path for mounting.
   --  @return True on success, False on failure.
   function Mount (Name, Path : String) return Boolean;

   --  Unmount a mount, syncing when possible.
   --  @param Path Path of the mount to unmount.
   procedure Unmount (Path : String);

   --  Get a mount mounted exactly in the passed path.
   --  @param Path Path to search a mount for.
   --  @return Key to use to refer to the mount, or 0 if not found.
   --  TODO: Make this do a closest instead of exact match in order to support
   --  mounts better, along with file dispatching in vfs-file.adb.
   function Get_Mount (Path : String) return FS_Handle;

   --  Get the backing FS type.
   --  @param Key Key to use to fetch the info.
   --  @return The FS type, will be a placeholder if the key is not valid.
   function Get_Backing_FS (Key : FS_Handle) return FS_Type
      with Pre => Key /= Error_Handle;

   --  Get the backing data of the FS.
   --  @param Key Key to use to fetch the info.
   --  @return The FS data, or System.Null_Address if not a valid key.
   function Get_Backing_FS_Data (Key : FS_Handle) return System.Address
      with Pre => Key /= Error_Handle;

   --  Get the backing device of a mount.
   --  @param Key Key to use to fetch the info.
   --  @return The backing device.
   function Get_Backing_Device (Key : FS_Handle) return Device_Handle
      with Pre => Key /= Error_Handle;

   --  Open a file with an absolute path inside the mount.
   --  @param Key  FS Handle to open.
   --  @param Path Absolute path inside the mount, creation is not done.
   --  @return Returned opaque pointer for the passed mount, Null in failure.
   function Open (Key : FS_Handle; Path : String) return System.Address
      with Pre => Key /= Error_Handle;

   --  Create a file with an absolute path inside the mount.
   --  @param Key  FS Handle to open.
   --  @param Path Absolute path inside the mount, must not exist.
   --  @param Mode Mode to use for the created file.
   --  @return Returned opaque pointer for the passed mount, Null in failure.
   function Create
      (Key  : FS_Handle;
       Path : String;
       Mode : Unsigned_32) return System.Address
      with Pre => Key /= Error_Handle;

   --  Close an already opened file.
   --  @param Key FS handle to operate on.
   --  @param Obj Object to close and free, will be set to Null.
   procedure Close (Key : FS_Handle; Obj : out System.Address)
      with Pre => Key /= Error_Handle and Obj /= System.Null_Address;

   --  Read the entries of an opened directory.
   --  @param Key       FS handle to operate on.
   --  @param Obj       Object to read the entries of.
   --  @param Entities  Where to store the read entries, as many as possible.
   --  @param Ret_Count The count of entries, even if num > Entities'Length.
   --  @param Success   True in success, False in failure.
   procedure Read_Entries
      (Key       : FS_Handle;
       Obj       : System.Address;
       Entities  : out Directory_Entities;
       Ret_Count : out Natural;
       Success   : out Boolean)
      with Pre => Key /= Error_Handle and Obj /= System.Null_Address;

   --  Create a symlink with an absolute path inside the mount and a target.
   --  @param Key    FS Handle to open.
   --  @param Path   Absolute path inside the mount, must not exist.
   --  @param Target Target of the symlink, it is not checked in any way.
   --  @param Mode   Mode to use for the created symlink.
   --  @return Returned opaque pointer for the passed mount, Null in failure.
   function Create_Symbolic_Link
      (Key          : FS_Handle;
       Path, Target : String;
       Mode         : Unsigned_32) return System.Address
      with Pre => Key /= Error_Handle;

   --  Create a directory with an absolute path inside the mount.
   --  @param Key    FS Handle to open.
   --  @param Path   Absolute path inside the mount, must not exist.
   --  @param Mode   Mode to use for the created directory.
   --  @return Returned opaque pointer for the passed mount, Null in failure.
   function Create_Directory
      (Key  : FS_Handle;
       Path : String;
       Mode : Unsigned_32) return System.Address
      with Pre => Key /= Error_Handle;

   --  Read from a regular file.
   --  @param Key       FS Handle to open.
   --  @param Obj       Object to read from.
   --  @param Offset    Offset to read from.
   --  @param Data      Place to write read data.
   --  @param Ret_Count How many items were read into Data until EOF.
   --  @param Success   True on success, False on failure.
   procedure Read
      (Key       : FS_Handle;
       Obj       : System.Address;
       Offset    : Unsigned_64;
       Data      : out Operation_Data;
       Ret_Count : out Natural;
       Success   : out Boolean)
      with Pre => Key /= Error_Handle and Obj /= System.Null_Address;

   --  Write to a regular file.
   --  @param Key       FS Handle to open.
   --  @param Obj       Object to write to.
   --  @param Offset    Offset to write to.
   --  @param Data      Data to write
   --  @param Ret_Count How many items were written until EOF.
   --  @param Success   True on success, False on failure.
   procedure Write
      (Key       : FS_Handle;
       Obj       : System.Address;
       Offset    : Unsigned_64;
       Data      : Operation_Data;
       Ret_Count : out Natural;
       Success   : out Boolean)
      with Pre => Key /= Error_Handle and Obj /= System.Null_Address;

   --  Get the stat of a file.
   --  @param Key FS Handle to open.
   --  @param Obj Object to fetch information for.
   --  @param S   Data to fetch.
   --  @return True on success, False on failure.
   function Stat
      (Key  : FS_Handle;
       Obj  : System.Address;
       S    : out File_Stat) return Boolean
      with Pre => Key /= Error_Handle and Obj /= System.Null_Address;
   ----------------------------------------------------------------------------
   --  Check whether a path is absolute.
   --  @param Path to check.
   --  @return True if absolute, False if not.
   function Is_Absolute (Path : String) return Boolean;

   --  Check whether a path is canonical, that is, whether the path is the
   --  shortest form it could be, symlinks are not checked.
   --  @param Path Path to check.
   --  @return True if canonical, False if not.
   function Is_Canonical (Path : String) return Boolean;

private

   type FS_Handle is new Natural range 0 .. 5;
   Error_Handle : constant FS_Handle := 0;
end VFS;
