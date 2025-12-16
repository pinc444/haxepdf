/*
 * format - Haxe File Formats
 * CMap Parser for PDF ToUnicode streams
 */
package format.pdf;

import haxe.io.Bytes;

/**
 * Parses PDF ToUnicode CMap streams to build character code to Unicode mappings.
 * 
 * CMap format example:
 * beginbfchar
 * <0001> <0041>
 * endbfchar
 * beginbfrange
 * <0020> <007E> <0020>
 * endbfrange
 */
class CMapParser {
    
    /**
     * Convert a Unicode code point to a UTF-8 encoded string.
     * This is necessary because Neko's String.fromCharCode doesn't handle Unicode > 255 properly.
     */
    public static function codePointToUtf8(codePoint:Int):String {
        if (codePoint < 0x80) {
            // ASCII - single byte
            return String.fromCharCode(codePoint);
        } else if (codePoint < 0x800) {
            // 2-byte UTF-8
            var b1 = 0xC0 | (codePoint >> 6);
            var b2 = 0x80 | (codePoint & 0x3F);
            return String.fromCharCode(b1) + String.fromCharCode(b2);
        } else if (codePoint < 0x10000) {
            // 3-byte UTF-8
            var b1 = 0xE0 | (codePoint >> 12);
            var b2 = 0x80 | ((codePoint >> 6) & 0x3F);
            var b3 = 0x80 | (codePoint & 0x3F);
            return String.fromCharCode(b1) + String.fromCharCode(b2) + String.fromCharCode(b3);
        } else if (codePoint < 0x110000) {
            // 4-byte UTF-8
            var b1 = 0xF0 | (codePoint >> 18);
            var b2 = 0x80 | ((codePoint >> 12) & 0x3F);
            var b3 = 0x80 | ((codePoint >> 6) & 0x3F);
            var b4 = 0x80 | (codePoint & 0x3F);
            return String.fromCharCode(b1) + String.fromCharCode(b2) + String.fromCharCode(b3) + String.fromCharCode(b4);
        }
        // Invalid code point
        return "";
    }
    
    /**
     * Parse a CMap stream and return a mapping of character codes to Unicode strings
     */
    public static function parse(bytes:Bytes):Map<Int, String> {
        var mapping = new Map<Int, String>();
        var str = bytes.toString();
        
        // Parse bfchar sections (individual character mappings)
        parseBfChar(str, mapping);
        
        // Parse bfrange sections (range mappings)
        parseBfRange(str, mapping);
        
        return mapping;
    }

    /**
     * Parse beginbfchar ... endbfchar sections
     * Format: <srcCode> <dstString>
     */
    static function parseBfChar(str:String, mapping:Map<Int, String>) {
        var bfcharPattern = ~/beginbfchar\s*([\s\S]*?)\s*endbfchar/g;
        
        while (bfcharPattern.match(str)) {
            var content = bfcharPattern.matched(1);
            parseCharMappings(content, mapping);
            str = bfcharPattern.matchedRight();
        }
    }

    /**
     * Parse beginbfrange ... endbfrange sections
     * Format: <srcCodeLo> <srcCodeHi> <dstStringLo>
     * Or:     <srcCodeLo> <srcCodeHi> [<dstString1> <dstString2> ...]
     */
    static function parseBfRange(str:String, mapping:Map<Int, String>) {
        var bfrangePattern = ~/beginbfrange\s*([\s\S]*?)\s*endbfrange/g;
        
        while (bfrangePattern.match(str)) {
            var content = bfrangePattern.matched(1);
            parseRangeMappings(content, mapping);
            str = bfrangePattern.matchedRight();
        }
    }

    /**
     * Parse individual character mappings from bfchar content
     */
    static function parseCharMappings(content:String, mapping:Map<Int, String>) {
        var linePattern = ~/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/g;
        
        while (linePattern.match(content)) {
            var srcHex = linePattern.matched(1);
            var dstHex = linePattern.matched(2);
            
            var srcCode = parseHexInt(srcHex);
            var dstStr = hexToUnicodeString(dstHex);
            
            mapping.set(srcCode, dstStr);
            content = linePattern.matchedRight();
        }
    }

    /**
     * Parse range mappings from bfrange content
     */
    static function parseRangeMappings(content:String, mapping:Map<Int, String>) {
        // Pattern for range with single destination: <lo> <hi> <dst>
        var rangePattern = ~/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/g;
        var remaining = content;
        
        while (rangePattern.match(remaining)) {
            var loHex = rangePattern.matched(1);
            var hiHex = rangePattern.matched(2);
            var dstHex = rangePattern.matched(3);
            
            var loCode = parseHexInt(loHex);
            var hiCode = parseHexInt(hiHex);
            var dstStart = parseHexInt(dstHex);
            
            // Map the range
            var offset = 0;
            for (code in loCode...(hiCode + 1)) {
                var unicode = dstStart + offset;
                mapping.set(code, codePointToUtf8(unicode));
                offset++;
            }
            
            remaining = rangePattern.matchedRight();
        }
        
        // Pattern for range with array destination: <lo> <hi> [<dst1> <dst2> ...]
        var arrayPattern = ~/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*\[([\s\S]*?)\]/g;
        remaining = content;
        
        while (arrayPattern.match(remaining)) {
            var loHex = arrayPattern.matched(1);
            var hiHex = arrayPattern.matched(2);
            var arrayContent = arrayPattern.matched(3);
            
            var loCode = parseHexInt(loHex);
            var hiCode = parseHexInt(hiHex);
            
            // Parse array of destination strings
            var dstStrings = parseHexArray(arrayContent);
            
            var offset = 0;
            for (code in loCode...(hiCode + 1)) {
                if (offset < dstStrings.length) {
                    mapping.set(code, dstStrings[offset]);
                }
                offset++;
            }
            
            remaining = arrayPattern.matchedRight();
        }
    }

    /**
     * Parse a hex string to integer
     */
    static function parseHexInt(hex:String):Int {
        return Std.parseInt("0x" + hex);
    }

    /**
     * Convert hex string to Unicode string
     * Handles both 2-byte and 4-byte (or longer) hex sequences
     */
    static function hexToUnicodeString(hex:String):String {
        var result = new StringBuf();
        var i = 0;
        
        // Process in 4-character (2-byte) chunks for UTF-16
        while (i < hex.length) {
            var chunkLen = 4;
            if (i + chunkLen > hex.length) {
                chunkLen = hex.length - i;
            }
            
            var chunk = hex.substr(i, chunkLen);
            var codePoint = Std.parseInt("0x" + chunk);
            
            // Skip null or invalid code points
            if (codePoint == null || codePoint == 0) {
                i += chunkLen;
                continue;
            }
            
            // Handle surrogate pairs for characters outside BMP
            if (codePoint >= 0xD800 && codePoint <= 0xDBFF && i + 4 < hex.length) {
                // High surrogate - look for low surrogate
                var nextChunk = hex.substr(i + 4, 4);
                var lowSurrogate = Std.parseInt("0x" + nextChunk);
                if (lowSurrogate != null && lowSurrogate >= 0xDC00 && lowSurrogate <= 0xDFFF) {
                    // Combine surrogates
                    codePoint = 0x10000 + ((codePoint - 0xD800) << 10) + (lowSurrogate - 0xDC00);
                    i += 4;
                }
            }
            
            // Use proper UTF-8 encoding for all code points
            result.add(codePointToUtf8(codePoint));
            
            i += chunkLen;
        }
        
        return result.toString();
    }

    /**
     * Parse an array of hex strings
     */
    static function parseHexArray(content:String):Array<String> {
        var result = new Array<String>();
        var hexPattern = ~/<([0-9A-Fa-f]+)>/g;
        
        while (hexPattern.match(content)) {
            var hex = hexPattern.matched(1);
            result.push(hexToUnicodeString(hex));
            content = hexPattern.matchedRight();
        }
        
        return result;
    }
}
