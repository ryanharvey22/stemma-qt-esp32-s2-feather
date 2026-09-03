-- Host tool: .bin -> .uf2 for TinyUF2 on the ESP32-S2.
-- Build:  gnatmake -D build -o build/bin2uf2 tools/bin2uf2.adb
--
-- Ada has no #define. Use named numbers / typed constants (see below).
-- The C `uint32_t *w = (uint32_t *)blk` overlay is a record here.

with Ada.Command_Line;         use Ada.Command_Line;
with Ada.Text_IO;
with Ada.Streams;              use Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Conversion;
with Interfaces;               use Interfaces;
with System;

procedure Bin2UF2 is
   package SIO renames Ada.Streams.Stream_IO;

   -- C: #define FAMILY 0xbfdd4eeeU  etc.  `constant :=` is untyped (like a macro).
   Family        : constant := 16#BFDD4EEE#;
   Payload       : constant := 256;
   Flags         : constant := 16#2000#;
   Default_Base  : constant := 16#10000#;
   Block_Bytes   : constant := 512;
   Data_Region   : constant := 476;  -- bytes between header and magic_end

   subtype Payload_Index is Natural range 0 .. Payload - 1;
   type Payload_Bytes is array (Payload_Index) of Unsigned_8
     with Component_Size => 8;

   subtype Pad_Index is Natural range 0 .. Data_Region - Payload - 1;
   type Pad_Bytes is array (Pad_Index) of Unsigned_8
     with Component_Size => 8;

   type UF2_Block is record
      Magic_Start_0 : Unsigned_32 := 16#0A324655#;
      Magic_Start_1 : Unsigned_32 := 16#9E5D5157#;
      Block_Flags   : Unsigned_32 := Flags;
      Target_Addr   : Unsigned_32 := 0;
      Payload_Size  : Unsigned_32 := 0;
      Block_No      : Unsigned_32 := 0;
      Num_Blocks    : Unsigned_32 := 0;
      Family_ID     : Unsigned_32 := Family;
      Data          : Payload_Bytes := (others => 0);
      Pad           : Pad_Bytes := (others => 0);
      Magic_End     : Unsigned_32 := 16#0AB16F30#;
   end record
     with Size => Block_Bytes * 8, Alignment => 4, Bit_Order => System.Low_Order_First;

   for UF2_Block use record
      Magic_Start_0 at 0   range 0 .. 31;
      Magic_Start_1 at 4   range 0 .. 31;
      Block_Flags   at 8   range 0 .. 31;
      Target_Addr   at 12  range 0 .. 31;
      Payload_Size  at 16  range 0 .. 31;
      Block_No      at 20  range 0 .. 31;
      Num_Blocks    at 24  range 0 .. 31;
      Family_ID     at 28  range 0 .. 31;
      Data          at 32  range 0 .. Payload * 8 - 1;
      Pad           at 32 + Payload range 0 .. (Data_Region - Payload) * 8 - 1;
      Magic_End     at 508 range 0 .. 31;
   end record;

   type Block_Bytes_Array is array (1 .. Block_Bytes) of Unsigned_8
     with Pack, Size => Block_Bytes * 8;

   function To_Bytes is new Ada.Unchecked_Conversion (UF2_Block, Block_Bytes_Array);

   function Parse_U32 (S : String) return Unsigned_32 is
   begin
      if S'Length >= 2
        and then (S (S'First .. S'First + 1) = "0x"
                  or else S (S'First .. S'First + 1) = "0X")
      then
         return Unsigned_32'Value ("16#" & S (S'First + 2 .. S'Last) & "#");
      end if;
      return Unsigned_32'Value (S);
   end Parse_U32;

   Base : Unsigned_32 := Default_Base;
   In_File, Out_File : SIO.File_Type;
begin
   if Argument_Count < 2 or else Argument_Count > 3 then
      Ada.Text_IO.Put_Line ("usage: bin2uf2 in.bin out.uf2 [flash_addr]");
      Set_Exit_Status (Failure);
      return;
   end if;

   if Argument_Count = 3 then
      Base := Parse_U32 (Argument (3));
   end if;

   SIO.Open (In_File, SIO.In_File, Argument (1));
   -- TODO: finish this function
   SIO.Close (In_File);

   Ada.Text_IO.Put_Line ("opened " & Argument (1) & " (write the loop next)");
end Bin2UF2;
