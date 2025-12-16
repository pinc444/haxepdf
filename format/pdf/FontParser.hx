package format.pdf;

import haxe.io.Bytes;
import haxe.io.BytesInput;

/**
 * Parses embedded TrueType/OpenType font programs to extract glyph-to-character mappings.
 * This is essential for decoding identity-encoded CIDFonts that lack ToUnicode CMaps.
 */
class FontParser {
    // Glyph ID to Unicode codepoint mapping
    public var glyphToUnicode:Map<Int, Int>;
    
    // Font name for debugging
    public var fontName:String;
    
    public function new() {
        glyphToUnicode = new Map<Int, Int>();
        fontName = "";
    }
    
    /**
     * Parse a TrueType/OpenType font from raw bytes.
     * Returns true if parsing succeeded and glyph mappings were extracted.
     */
    public function parse(data:Bytes):Bool {
        if (data == null || data.length < 12) {
            return false;
        }
        
        var input = new BytesInput(data);
        
        // Check for TrueType/OpenType signature
        var version = input.readInt32();
        
        // TrueType: 0x00010000 or 'true' (0x74727565)
        // OpenType with CFF: 'OTTO' (0x4F54544F)
        // TrueType Collection: 'ttcf'
        
        var isTrueType = (version == 0x00010000 || version == 0x74727565);
        var isOpenType = (version == 0x4F54544F);
        
        if (!isTrueType && !isOpenType) {
            // Try reading as big-endian
            input.position = 0;
            input.bigEndian = true;
            version = input.readInt32();
            isTrueType = (version == 0x00010000 || version == 0x74727565);
            isOpenType = (version == 0x4F54544F);
        }
        
        if (!isTrueType && !isOpenType) {
            // Could be a CFF font (Type 1C)
            return parseCFF(data);
        }
        
        input.bigEndian = true;
        input.position = 4;
        
        // Read offset table
        var numTables = input.readUInt16();
        var searchRange = input.readUInt16();
        var entrySelector = input.readUInt16();
        var rangeShift = input.readUInt16();
        
        // Read table directory
        var tables = new Map<String, {offset:Int, length:Int}>();
        
        for (i in 0...numTables) {
            var tag = "";
            for (j in 0...4) {
                tag += String.fromCharCode(input.readByte());
            }
            var checksum = input.readInt32();
            var offset = input.readInt32();
            var length = input.readInt32();
            
            tables.set(tag, {offset: offset, length: length});
        }
        
        // Parse 'cmap' table for character mappings
        if (tables.exists("cmap")) {
            var cmapInfo = tables.get("cmap");
            parseCmapTable(data, cmapInfo.offset, cmapInfo.length);
        }
        
        // Parse 'name' table for font name
        if (tables.exists("name")) {
            var nameInfo = tables.get("name");
            parseNameTable(data, nameInfo.offset, nameInfo.length);
        }
        
        return glyphToUnicode.iterator().hasNext();
    }
    
    /**
     * Parse the 'cmap' table to extract glyph-to-unicode mappings.
     */
    function parseCmapTable(data:Bytes, offset:Int, length:Int):Void {
        if (offset + 4 > data.length) return;
        
        var input = new BytesInput(data);
        input.bigEndian = true;
        input.position = offset;
        
        var version = input.readUInt16();
        var numTables = input.readUInt16();
        
        // Look for the best encoding table
        // Priority: Platform 3 (Windows), Encoding 10 (Unicode full) or 1 (Unicode BMP)
        // Then: Platform 0 (Unicode), Encoding 3 or 4
        
        var bestOffset = -1;
        var bestFormat = -1;
        var bestPriority = -1;
        
        for (i in 0...numTables) {
            if (input.position + 8 > data.length) break;
            
            var platformId = input.readUInt16();
            var encodingId = input.readUInt16();
            var subtableOffset = input.readInt32();
            
            var priority = 0;
            
            // Windows Unicode BMP (most common)
            if (platformId == 3 && encodingId == 1) priority = 10;
            // Windows Unicode full
            else if (platformId == 3 && encodingId == 10) priority = 11;
            // Unicode platform
            else if (platformId == 0 && encodingId >= 3) priority = 9;
            else if (platformId == 0) priority = 8;
            // Mac Roman
            else if (platformId == 1 && encodingId == 0) priority = 5;
            
            if (priority > bestPriority) {
                bestPriority = priority;
                bestOffset = offset + subtableOffset;
            }
        }
        
        if (bestOffset >= 0 && bestOffset < data.length) {
            parseCmapSubtable(data, bestOffset);
        }
    }
    
    /**
     * Parse a cmap subtable based on its format.
     */
    function parseCmapSubtable(data:Bytes, offset:Int):Void {
        if (offset + 2 > data.length) return;
        
        var input = new BytesInput(data);
        input.bigEndian = true;
        input.position = offset;
        
        var format = input.readUInt16();
        
        switch (format) {
            case 0:
                parseCmapFormat0(input);
            case 4:
                parseCmapFormat4(input, offset);
            case 6:
                parseCmapFormat6(input);
            case 12:
                parseCmapFormat12(input, offset);
            default:
                // Unsupported format
        }
    }
    
    /**
     * Format 0: Byte encoding table (simple 1-byte mappings)
     */
    function parseCmapFormat0(input:BytesInput):Void {
        var length = input.readUInt16();
        var language = input.readUInt16();
        
        for (charCode in 0...256) {
            if (input.position >= input.length) break;
            var glyphId = input.readByte();
            if (glyphId > 0) {
                glyphToUnicode.set(glyphId, charCode);
            }
        }
    }
    
    /**
     * Format 4: Segment mapping to delta values (most common for BMP)
     */
    function parseCmapFormat4(input:BytesInput, tableOffset:Int):Void {
        var length = input.readUInt16();
        var language = input.readUInt16();
        var segCountX2 = input.readUInt16();
        var segCount = Std.int(segCountX2 / 2);
        var searchRange = input.readUInt16();
        var entrySelector = input.readUInt16();
        var rangeShift = input.readUInt16();
        
        // Read arrays
        var endCodes = new Array<Int>();
        for (i in 0...segCount) {
            endCodes.push(input.readUInt16());
        }
        
        var reservedPad = input.readUInt16(); // Should be 0
        
        var startCodes = new Array<Int>();
        for (i in 0...segCount) {
            startCodes.push(input.readUInt16());
        }
        
        var idDeltas = new Array<Int>();
        for (i in 0...segCount) {
            // idDelta is a signed 16-bit value
            var delta = input.readUInt16();
            if (delta > 32767) delta -= 65536;
            idDeltas.push(delta);
        }
        
        var idRangeOffsetPos = input.position;
        var idRangeOffsets = new Array<Int>();
        for (i in 0...segCount) {
            idRangeOffsets.push(input.readUInt16());
        }
        
        // Now map characters to glyphs (and we want the reverse)
        for (seg in 0...segCount) {
            var startCode = startCodes[seg];
            var endCode = endCodes[seg];
            var idDelta = idDeltas[seg];
            var idRangeOffset = idRangeOffsets[seg];
            
            if (startCode == 0xFFFF) continue;
            
            for (charCode in startCode...(endCode + 1)) {
                var glyphId:Int;
                
                if (idRangeOffset == 0) {
                    glyphId = (charCode + idDelta) & 0xFFFF;
                } else {
                    // Calculate offset into glyph id array
                    var glyphIdArrayOffset = idRangeOffsetPos + seg * 2 + idRangeOffset + (charCode - startCode) * 2;
                    if (glyphIdArrayOffset + 2 <= input.length) {
                        input.position = glyphIdArrayOffset;
                        glyphId = input.readUInt16();
                        if (glyphId != 0) {
                            glyphId = (glyphId + idDelta) & 0xFFFF;
                        }
                    } else {
                        continue;
                    }
                }
                
                if (glyphId > 0 && charCode > 0 && charCode < 0xFFFF) {
                    // Store mapping (glyph ID -> Unicode)
                    // Only store if not already mapped (first mapping wins)
                    if (!glyphToUnicode.exists(glyphId)) {
                        glyphToUnicode.set(glyphId, charCode);
                    }
                }
            }
        }
    }
    
    /**
     * Format 6: Trimmed table mapping
     */
    function parseCmapFormat6(input:BytesInput):Void {
        var length = input.readUInt16();
        var language = input.readUInt16();
        var firstCode = input.readUInt16();
        var entryCount = input.readUInt16();
        
        for (i in 0...entryCount) {
            if (input.position + 2 > input.length) break;
            var glyphId = input.readUInt16();
            var charCode = firstCode + i;
            if (glyphId > 0) {
                glyphToUnicode.set(glyphId, charCode);
            }
        }
    }
    
    /**
     * Format 12: Segmented coverage (for full Unicode)
     */
    function parseCmapFormat12(input:BytesInput, tableOffset:Int):Void {
        var reserved = input.readUInt16();
        var length = input.readInt32();
        var language = input.readInt32();
        var numGroups = input.readInt32();
        
        for (i in 0...numGroups) {
            if (input.position + 12 > input.length) break;
            
            var startCharCode = input.readInt32();
            var endCharCode = input.readInt32();
            var startGlyphId = input.readInt32();
            
            // Limit range to prevent memory issues
            var rangeSize = endCharCode - startCharCode;
            if (rangeSize > 10000) continue;
            
            for (j in 0...(rangeSize + 1)) {
                var charCode = startCharCode + j;
                var glyphId = startGlyphId + j;
                
                if (glyphId > 0 && charCode > 0 && charCode < 0x10FFFF) {
                    if (!glyphToUnicode.exists(glyphId)) {
                        glyphToUnicode.set(glyphId, charCode);
                    }
                }
            }
        }
    }
    
    /**
     * Parse the 'name' table to get the font name.
     */
    function parseNameTable(data:Bytes, offset:Int, length:Int):Void {
        if (offset + 6 > data.length) return;
        
        var input = new BytesInput(data);
        input.bigEndian = true;
        input.position = offset;
        
        var format = input.readUInt16();
        var count = input.readUInt16();
        var stringOffset = input.readUInt16();
        
        var storageOffset = offset + stringOffset;
        
        for (i in 0...count) {
            if (input.position + 12 > data.length) break;
            
            var platformId = input.readUInt16();
            var encodingId = input.readUInt16();
            var languageId = input.readUInt16();
            var nameId = input.readUInt16();
            var nameLength = input.readUInt16();
            var nameOffset = input.readUInt16();
            
            // Name ID 4 = Full font name, 6 = PostScript name
            if (nameId == 4 || nameId == 6) {
                if (storageOffset + nameOffset + nameLength <= data.length) {
                    var nameStart = storageOffset + nameOffset;
                    var nameBytes = data.sub(nameStart, nameLength);
                    
                    // Try to decode as UTF-16BE (Windows platform) or ASCII
                    if (platformId == 3 || platformId == 0) {
                        fontName = decodeUtf16BE(nameBytes);
                    } else {
                        fontName = nameBytes.toString();
                    }
                    
                    if (fontName.length > 0) {
                        return; // Got a name
                    }
                }
            }
        }
    }
    
    /**
     * Decode UTF-16BE bytes to string.
     */
    function decodeUtf16BE(data:Bytes):String {
        var result = new StringBuf();
        var i = 0;
        while (i + 1 < data.length) {
            var charCode = (data.get(i) << 8) | data.get(i + 1);
            if (charCode > 0 && charCode < 128) {
                result.addChar(charCode);
            }
            i += 2;
        }
        return result.toString();
    }
    
    /**
     * Parse CFF (Compact Font Format) data.
     * CFF fonts are more complex; this provides basic support.
     */
    function parseCFF(data:Bytes):Bool {
        // CFF parsing is complex. For now, return false.
        // Full CFF support would require parsing:
        // - Header
        // - Name INDEX
        // - Top DICT INDEX  
        // - String INDEX
        // - Global Subr INDEX
        // - Charsets
        // - Encodings
        // - CharStrings INDEX
        
        // Check for CFF header
        if (data.length < 4) return false;
        
        var major = data.get(0);
        var minor = data.get(1);
        var hdrSize = data.get(2);
        
        // CFF version 1.x
        if (major == 1 && hdrSize >= 4) {
            // This is a valid CFF font, but we'd need full parsing
            // to extract glyph mappings
            return false;
        }
        
        return false;
    }
    
    /**
     * Get the Unicode character for a glyph ID.
     * Returns -1 if not found.
     */
    public function getUnicodeForGlyph(glyphId:Int):Int {
        if (glyphToUnicode.exists(glyphId)) {
            return glyphToUnicode.get(glyphId);
        }
        return -1;
    }
    
    /**
     * Decode a string of glyph IDs to Unicode text.
     */
    public function decodeGlyphString(glyphIds:Array<Int>):String {
        var result = new StringBuf();
        for (gid in glyphIds) {
            var unicode = getUnicodeForGlyph(gid);
            if (unicode > 0) {
                if (unicode < 256) {
                    result.addChar(unicode);
                } else {
                    // For Unicode > 255, use escape or placeholder
                    result.add(String.fromCharCode(unicode));
                }
            }
        }
        return result.toString();
    }
    
    /**
     * Debug: Get statistics about parsed mappings.
     */
    public function getStats():String {
        var count = 0;
        for (_ in glyphToUnicode) count++;
        return 'FontParser: ${fontName}, ${count} glyph mappings';
    }
}
