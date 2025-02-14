--  s-imgint.ads: Integer printing version.
--
--  This specification is derived from the Ada Reference Manual. In accordance
--  with the copyright of the original source, you can freely copy and modify
--  this specification, provided that if you redistribute a modified version,
--  any changes are clearly indicated.
--
--  This file is based on the distribution by the GNAT project, which is
--  distributed under the GPLv3 with the GCC runtime exception.

package System.Img_Int is
   procedure Image_Integer
     (V : Integer;
      S : in out String;
      P : out Natural);
end System.Img_Int;
