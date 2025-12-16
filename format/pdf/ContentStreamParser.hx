/*
 * format - Haxe File Formats
 * Content Stream Parser for PDF text extraction
 */
package format.pdf;

import haxe.io.Bytes;
import format.pdf.TextExtractor.FontInfo;

/**
 * Parses PDF content streams to extract text.
 * 
 * Text is rendered using operators like:
 * - Tj: Show text string
 * - TJ: Show text with individual glyph positioning
 * - ': Move to next line and show text
 * - ": Set spacing, move to next line, show text
 * 
 * Font is selected with Tf operator: /FontName size Tf
 */
class ContentStreamParser {
    
    /**
     * Extract text from a content stream using the provided font mappings
     */
    public static function extractText(stream:Bytes, pageFonts:Map<String, FontInfo>, allFonts:Map<String, FontInfo>):String {
        var result = new StringBuf();
        var str = stream.toString();
        var currentFont:FontInfo = null;
        
        var i = 0;
        var len = str.length;
        
        while (i < len) {
            // Skip whitespace
            while (i < len && isWhitespace(str.charCodeAt(i))) {
                i++;
            }
            
            if (i >= len) break;
            
            var c = str.charCodeAt(i);
            
            // Check for font selection: /FontName size Tf
            if (c == 47) { // '/'
                var fontName = readName(str, i);
                if (fontName != null) {
                    i += fontName.length + 1;
                    
                    // Skip to Tf operator
                    var tfPos = findOperator(str, i, "Tf");
                    if (tfPos != -1 && tfPos - i < 50) {
                        // Look up font
                        if (pageFonts.exists(fontName)) {
                            currentFont = pageFonts.get(fontName);
                        } else if (allFonts.exists(fontName)) {
                            currentFont = allFonts.get(fontName);
                        }
                        i = tfPos + 2;
                        continue;
                    }
                }
            }
            
            // Check for text operators
            if (c == 40) { // '(' - start of string, likely followed by Tj or '
                var textResult = readStringAndOperator(str, i);
                if (textResult != null) {
                    var text = decodeText(textResult.text, currentFont, stream, textResult.startPos);
                    result.add(text);
                    i = textResult.endPos;
                    continue;
                }
            }
            
            // Check for hex string
            if (c == 60 && i + 1 < len && str.charCodeAt(i + 1) != 60) { // '<' but not '<<'
                var hexResult = readHexStringAndOperator(str, i);
                if (hexResult != null) {
                    var text = decodeHexText(hexResult.text, currentFont);
                    result.add(text);
                    i = hexResult.endPos;
                    continue;
                }
            }
            
            // Check for TJ operator (array of strings)
            if (c == 91) { // '['
                var arrayResult = readArrayAndOperator(str, i);
                if (arrayResult != null) {
                    for (item in arrayResult.items) {
                        var text = decodeText(item.text, currentFont, stream, item.startPos);
                        result.add(text);
                    }
                    i = arrayResult.endPos;
                    continue;
                }
            }
            
            // Check for BT (begin text) - add newline for text block separation
            if (c == 66 && i + 1 < len && str.charCodeAt(i + 1) == 84) { // "BT"
                // Verify it's the operator
                if ((i == 0 || isWhitespace(str.charCodeAt(i - 1))) && 
                    (i + 2 >= len || isWhitespace(str.charCodeAt(i + 2)))) {
                    i += 2;
                    continue;
                }
            }
            
            // Check for ET (end text) - add space for separation
            if (c == 69 && i + 1 < len && str.charCodeAt(i + 1) == 84) { // "ET"
                if ((i == 0 || isWhitespace(str.charCodeAt(i - 1))) && 
                    (i + 2 >= len || isWhitespace(str.charCodeAt(i + 2)))) {
                    result.add(" ");
                    i += 2;
                    continue;
                }
            }
            
            // Move to next character
            i++;
        }
        
        return result.toString();
    }

    static function isWhitespace(c:Int):Bool {
        return c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32;
    }

    static function readName(str:String, pos:Int):String {
        if (pos >= str.length || str.charCodeAt(pos) != 47) return null;
        
        var result = new StringBuf();
        var i = pos + 1;
        
        while (i < str.length) {
            var c = str.charCodeAt(i);
            if (isWhitespace(c) || c == 47 || c == 40 || c == 41 || c == 60 || c == 62 || c == 91 || c == 93) {
                break;
            }
            result.addChar(c);
            i++;
        }
        
        return result.toString();
    }

    static function findOperator(str:String, startPos:Int, op:String):Int {
        var i = startPos;
        while (i < str.length - op.length + 1) {
            var match = true;
            for (j in 0...op.length) {
                if (str.charCodeAt(i + j) != op.charCodeAt(j)) {
                    match = false;
                    break;
                }
            }
            if (match) {
                // Verify it's a standalone operator
                var before = i > 0 ? str.charCodeAt(i - 1) : 32;
                var after = i + op.length < str.length ? str.charCodeAt(i + op.length) : 32;
                if (isWhitespace(before) && isWhitespace(after)) {
                    return i;
                }
            }
            i++;
        }
        return -1;
    }

    static function readStringAndOperator(str:String, pos:Int):{text:String, startPos:Int, endPos:Int} {
        if (pos >= str.length || str.charCodeAt(pos) != 40) return null;
        
        var startPos = pos + 1;
        var depth = 1;
        var i = pos + 1;
        var result = new StringBuf();
        var escaped = false;
        
        while (i < str.length && depth > 0) {
            var c = str.charCodeAt(i);
            
            if (escaped) {
                // Handle escape sequences
                switch (c) {
                    case 110: result.addChar(10); // \n
                    case 114: result.addChar(13); // \r
                    case 116: result.addChar(9);  // \t
                    case 98: result.addChar(8);   // \b
                    case 102: result.addChar(12); // \f
                    case 40, 41, 92: result.addChar(c); // \( \) \\
                    case 48, 49, 50, 51, 52, 53, 54, 55: // Octal
                        var octal = new StringBuf();
                        octal.addChar(c);
                        if (i + 1 < str.length && str.charCodeAt(i + 1) >= 48 && str.charCodeAt(i + 1) <= 55) {
                            i++;
                            octal.addChar(str.charCodeAt(i));
                            if (i + 1 < str.length && str.charCodeAt(i + 1) >= 48 && str.charCodeAt(i + 1) <= 55) {
                                i++;
                                octal.addChar(str.charCodeAt(i));
                            }
                        }
                        var charCode = Std.parseInt("0o" + octal.toString());
                        if (charCode == null) charCode = Std.parseInt(octal.toString());
                        if (charCode != null) result.addChar(charCode);
                    default: result.addChar(c);
                }
                escaped = false;
            } else if (c == 92) { // backslash
                escaped = true;
            } else if (c == 40) { // (
                depth++;
                result.addChar(c);
            } else if (c == 41) { // )
                depth--;
                if (depth > 0) result.addChar(c);
            } else {
                result.addChar(c);
            }
            
            i++;
        }
        
        // Check if followed by text operator (Tj, ', ")
        var endPos = i;
        while (endPos < str.length && isWhitespace(str.charCodeAt(endPos))) {
            endPos++;
        }
        
        if (endPos < str.length) {
            var nextChar = str.charCodeAt(endPos);
            // Tj operator
            if (nextChar == 84 && endPos + 1 < str.length && str.charCodeAt(endPos + 1) == 106) {
                return {text: result.toString(), startPos: startPos, endPos: endPos + 2};
            }
            // ' operator
            if (nextChar == 39) {
                return {text: result.toString(), startPos: startPos, endPos: endPos + 1};
            }
            // " operator
            if (nextChar == 34) {
                return {text: result.toString(), startPos: startPos, endPos: endPos + 1};
            }
        }
        
        // Not a text operator, but still return the string for TJ array processing
        return {text: result.toString(), startPos: startPos, endPos: i};
    }

    static function readHexStringAndOperator(str:String, pos:Int):{text:String, endPos:Int} {
        if (pos >= str.length || str.charCodeAt(pos) != 60) return null;
        
        var result = new StringBuf();
        var i = pos + 1;
        
        while (i < str.length && str.charCodeAt(i) != 62) {
            var c = str.charCodeAt(i);
            if (!isWhitespace(c)) {
                result.addChar(c);
            }
            i++;
        }
        
        if (i < str.length) i++; // Skip >
        
        // Check if followed by text operator
        var endPos = i;
        while (endPos < str.length && isWhitespace(str.charCodeAt(endPos))) {
            endPos++;
        }
        
        if (endPos < str.length) {
            var nextChar = str.charCodeAt(endPos);
            if (nextChar == 84 && endPos + 1 < str.length && str.charCodeAt(endPos + 1) == 106) {
                return {text: result.toString(), endPos: endPos + 2};
            }
        }
        
        return {text: result.toString(), endPos: i};
    }

    static function readArrayAndOperator(str:String, pos:Int):{items:Array<{text:String, startPos:Int}>, endPos:Int} {
        if (pos >= str.length || str.charCodeAt(pos) != 91) return null;
        
        var items = new Array<{text:String, startPos:Int}>();
        var i = pos + 1;
        
        while (i < str.length && str.charCodeAt(i) != 93) {
            var c = str.charCodeAt(i);
            
            if (c == 40) { // String
                var strResult = readStringAndOperator(str, i);
                if (strResult != null) {
                    items.push({text: strResult.text, startPos: strResult.startPos});
                    i = strResult.endPos;
                    continue;
                }
            } else if (c == 60 && i + 1 < str.length && str.charCodeAt(i + 1) != 60) { // Hex string
                var hexResult = readHexStringAndOperator(str, i);
                if (hexResult != null) {
                    items.push({text: hexResult.text, startPos: i + 1});
                    i = hexResult.endPos;
                    continue;
                }
            }
            
            i++;
        }
        
        if (i < str.length) i++; // Skip ]
        
        // Check if followed by TJ operator
        var endPos = i;
        while (endPos < str.length && isWhitespace(str.charCodeAt(endPos))) {
            endPos++;
        }
        
        if (endPos + 1 < str.length && str.charCodeAt(endPos) == 84 && str.charCodeAt(endPos + 1) == 74) {
            return {items: items, endPos: endPos + 2};
        }
        
        return null; // Not a TJ array
    }

    static function decodeText(text:String, font:FontInfo, stream:Bytes, streamOffset:Int):String {
        if (font == null) {
            // No font info, return printable ASCII only
            var result = new StringBuf();
            for (i in 0...text.length) {
                var c = text.charCodeAt(i);
                if (c >= 32 && c < 127) {
                    result.addChar(c);
                } else if (c == 10 || c == 13) {
                    result.add(" ");
                }
            }
            return result.toString();
        }
        
        var result = new StringBuf();
        var i = 0;
        
        while (i < text.length) {
            var charCode = text.charCodeAt(i);
            
            // Try 2-byte lookup for CID fonts
            if (font.toUnicode != null && i + 1 < text.length) {
                var twoByteCode = (charCode << 8) | text.charCodeAt(i + 1);
                if (font.toUnicode.exists(twoByteCode)) {
                    result.add(font.toUnicode.get(twoByteCode));
                    i += 2;
                    continue;
                }
            }
            
            // Single byte lookup
            var decoded = font.decode(charCode);
            if (decoded.length > 0) {
                result.add(decoded);
            }
            i++;
        }
        
        return result.toString();
    }

    static function decodeHexText(hexStr:String, font:FontInfo):String {
        var result = new StringBuf();
        var i = 0;
        
        while (i < hexStr.length) {
            // Read 2 or 4 hex digits
            var chunkLen = 4;
            if (i + chunkLen > hexStr.length) {
                chunkLen = hexStr.length - i;
            }
            
            // First try 4 digits (2 bytes) for CID fonts
            if (chunkLen >= 4 && font != null && font.toUnicode != null) {
                var hex4 = hexStr.substr(i, 4);
                var code = Std.parseInt("0x" + hex4);
                if (code != null && font.toUnicode.exists(code)) {
                    result.add(font.toUnicode.get(code));
                    i += 4;
                    continue;
                }
            }
            
            // Try 2 digits (1 byte)
            if (chunkLen >= 2) {
                var hex2 = hexStr.substr(i, 2);
                var code = Std.parseInt("0x" + hex2);
                if (code != null) {
                    if (font != null) {
                        var decoded = font.decode(code);
                        if (decoded.length > 0) {
                            result.add(decoded);
                        }
                    } else if (code >= 32 && code < 127) {
                        result.addChar(code);
                    }
                }
                i += 2;
            } else {
                i++;
            }
        }
        
        return result.toString();
    }
}
