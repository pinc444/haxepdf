/*
 * format - Haxe File Formats
 * Text Extraction Extension for PDF
 */
package format.pdf;

import format.pdf.Data;
import format.pdf.Filter;
import format.pdf.CMapParser;
import format.pdf.ContentStreamParser;
import format.pdf.FontParser;
import haxe.io.Bytes;

/**
 * Extracts readable text from PDF documents.
 * Handles font decoding, ToUnicode CMaps, and content stream parsing.
 */
class TextExtractor {
    var objects:Map<Int, Data>;
    var fonts:Map<String, FontInfo>;
    var filter:Filter;
    var divider:String; // Divider between text blocks
    var debug:Bool;

    public function new(divider:String = "\n") {
        objects = new Map();
        fonts = new Map();
        filter = new Filter();
        this.divider = divider;
        this.debug = false;
    }
    
    public function setDebug(d:Bool):Void {
        debug = d;
    }
    
    function log(msg:String):Void {
        if (debug) {
            Sys.println("[DEBUG] " + msg);
        }
    }

    /**
     * Extract all text from a PDF document.
     * @param pdfData Array of PDF data objects from Reader
     * @return Extracted text as a string
     */
    public function extractText(pdfData:Array<Data>):String {
        // First, unfilter (decompress) all streams
        var unfiltered = filter.unfilter(pdfData);
        
        // Build object lookup table
        buildObjectTable(unfiltered);
        
        // Try to extract text from Object Streams first (PDF 1.5+)
        parseObjectStreams();
        
        // Find and parse all fonts
        parseFonts();
        
        // Extract text from all pages
        var result = new StringBuf();
        var pages = findPages();
        
        log("Found " + pages.length + " pages");
        
        var pageTextExtracted = false;
        if (pages.length > 0) {
            for (pageRef in pages) {
                var pageText = extractPageText(pageRef);
                log("Page " + pageRef + " text length: " + pageText.length);
                if (pageText.length > 0) {
                    result.add(pageText);
                    result.add("\n\n");
                    pageTextExtracted = true;
                }
            }
        }
        
        // Fallback: scan streams for text operators if no text was extracted
        if (!pageTextExtracted) {
            for (id in objects.keys()) {
                var obj = objects.get(id);
                switch (obj) {
                    case DStream(bytes, props):
                        // Skip known non-content streams
                        var typeData = props.get("Type");
                        var isXRef = switch(typeData) { case DName("XRef"): true; default: false; };
                        var isObjStm = switch(typeData) { case DName("ObjStm"): true; default: false; };
                        var isXObject = switch(typeData) { case DName("XObject"): true; default: false; };
                        
                        // Check subtype for fonts and images
                        var subtypeData = props.get("Subtype");
                        var isFont = switch(subtypeData) { case DName("Type1"): true; case DName("TrueType"): true; case DName("CIDFontType2"): true; case DName("OpenType"): true; default: false; };
                        var isImage = switch(subtypeData) { case DName("Image"): true; default: false; };
                        
                        if (!isXRef && !isObjStm && !isXObject && !isFont && !isImage) {
                            // Only process if it looks like a content stream (has BT/ET text operators)
                            var content = bytes.toString();
                            if (isContentStream(content)) {
                                var text = extractTextFromStreamWithFonts(bytes, fonts);
                                if (text.length > 0) {
                                    result.add(text);
                                    result.add(divider);
                                    //this I see in the document end
                                    //result.add("Only process if it looks like a content stream (has BT/ET text operators)");
                                }
                            }
                        }
                    default:
                }
            }
        }
        
        return result.toString();
    }
    
    /**
     * Check if a stream looks like a PDF content stream (has text operators)
     */
    function isContentStream(content:String):Bool {
        // Content streams have text blocks marked by BT (begin text) and ET (end text)
        // They also have operators like Tf (set font), Tj (show text), TJ (show text array)
        // Check for presence of text-related operators
        
        // Look for BT...ET pattern or text operators
        var hasBT = content.indexOf(" BT") >= 0 || content.indexOf("\nBT") >= 0 || content.indexOf("\rBT") >= 0;
        var hasET = content.indexOf(" ET") >= 0 || content.indexOf("\nET") >= 0 || content.indexOf("\rET") >= 0;
        var hasTj = content.indexOf(" Tj") >= 0 || content.indexOf(")Tj") >= 0;
        var hasTJ = content.indexOf(" TJ") >= 0 || content.indexOf("]TJ") >= 0;
        
        // Must have BT/ET pair or text show operators
        return (hasBT && hasET) || hasTj || hasTJ;
    }
    
    /**
     * Extract text from a content stream using font ToUnicode mappings
     * Now with proper spacing and line breaks based on PDF operators
     */
    function extractTextFromStreamWithFonts(bytes:Bytes, allFonts:Map<String, FontInfo>):String {
        var result = new StringBuf();
        var content = bytes.toString();
        
        // Debug: Show sample of content stream
        if (debug && content.length > 0) {
            var sample = content.substr(0, 200);
            sample = ~/[\r\n]+/g.replace(sample, " ");
            log("Content stream sample: " + sample);
        }
        
        // Current font ToUnicode map
        var currentToUnicode:Map<Int, String> = null;
        
        // Track text position for spacing/newlines
        var lastX:Float = 0;
        var lastY:Float = 0;
        var currentX:Float = 0;
        var currentY:Float = 0;
        var fontSize:Float = 12;
        var inTextBlock = false;
        var needSpace = false;
        var needNewline = false;
        
        var i = 0;
        var len = content.length;
        
        while (i < len) {
            // Skip whitespace
            while (i < len && isWhitespace(content.charCodeAt(i))) {
                i++;
            }
            if (i >= len) break;
            
            var c = content.charCodeAt(i);
            
            // Check for BT (begin text)
            if (c == 66 && i + 1 < len && content.charCodeAt(i + 1) == 84) { // 'BT'
                var afterBT = i + 2 < len ? content.charCodeAt(i + 2) : 32;
                if (isWhitespace(afterBT) || afterBT == 10 || afterBT == 13) {
                    inTextBlock = true;
                    i += 2;
                    continue;
                }
            }
            
            // Check for ET (end text)
            if (c == 69 && i + 1 < len && content.charCodeAt(i + 1) == 84) { // 'ET'
                var afterET = i + 2 < len ? content.charCodeAt(i + 2) : 32;
                if (isWhitespace(afterET) || afterET == 10 || afterET == 13 || i + 2 >= len) {
                    inTextBlock = false;
                    needNewline = true;
                    i += 2;
                    continue;
                }
            }
            
            // Look for /FontName (to get current font)
            if (c == 47) { // '/'
                var nameStart = i + 1;
                i++;
                while (i < len && !isWhitespace(content.charCodeAt(i)) && !isDelimiter(content.charCodeAt(i))) {
                    i++;
                }
                var fontName = content.substr(nameStart, i - nameStart);
                // Check if followed by Tf operator (font size Tf)
                var tfMatch = ~/^\s+([\d\.]+)\s+Tf/;
                var remaining = content.substr(i, 30);
                if (tfMatch.match(remaining)) {
                    if (allFonts.exists(fontName)) {
                        currentToUnicode = allFonts.get(fontName).toUnicode;
                    }
                    fontSize = Std.parseFloat(tfMatch.matched(1));
                    if (fontSize == null || Math.isNaN(fontSize)) fontSize = 12;
                }
                continue;
            }
            
            // Look for Td/TD operator (move text position)
            if (c == 84 && i + 1 < len) { // 'T'
                var next = content.charCodeAt(i + 1);
                if ((next == 100 || next == 68) && (i + 2 >= len || isWhitespace(content.charCodeAt(i + 2)))) { // 'd' or 'D'
                    // Td or TD - text position change, usually means new line or spacing
                    needNewline = true;
                    i += 2;
                    continue;
                }
                if (next == 42 && (i + 2 >= len || isWhitespace(content.charCodeAt(i + 2)))) { // '*'
                    // T* - move to start of next line
                    needNewline = true;
                    i += 2;
                    continue;
                }
                if (next == 109 && (i + 2 >= len || isWhitespace(content.charCodeAt(i + 2)))) { // 'm'
                    // Tm - text matrix, usually means repositioning
                    needNewline = true;
                    i += 2;
                    continue;
                }
            }
            
            // Look for TJ array (text with positioning)
            if (c == 91) { // '['
                var arrayStart = i + 1;
                var depth = 1;
                i++;
                while (i < len && depth > 0) {
                    var cc = content.charCodeAt(i);
                    if (cc == 91) depth++;
                    else if (cc == 93) depth--;
                    else if (cc == 40) { // skip string content
                        i++;
                        var strDepth = 1;
                        while (i < len && strDepth > 0) {
                            var sc = content.charCodeAt(i);
                            if (sc == 92) { i += 2; continue; } // escape
                            if (sc == 40) strDepth++;
                            if (sc == 41) strDepth--;
                            i++;
                        }
                        continue;
                    }
                    i++;
                }
                
                // Check if followed by TJ
                var afterArray = content.substr(i, 10);
                if (~/^\s*TJ/.match(afterArray)) {
                    // Add newline before if needed
                    if (needNewline && result.length > 0) {
                        result.add(divider);
                        //result.add("if followed by TJ");
                        needNewline = false;
                    }
                    
                    // Parse TJ array content
                    var arrayContent = content.substr(arrayStart, i - arrayStart - 1);
                    var tjText = parseTJArray(arrayContent, currentToUnicode, fontSize);
                    if (tjText.length > 0) {
                        result.add(tjText);
                    }
                }
                continue;
            }
            
            // Look for hex string
            if (c == 60 && i + 1 < len && content.charCodeAt(i + 1) != 60) { // '<' but not '<<'
                var hexStart = i + 1;
                i++;
                while (i < len && content.charCodeAt(i) != 62) { // '>'
                    i++;
                }
                var hexContent = content.substr(hexStart, i - hexStart);
                
                // Check if followed by Tj
                var afterHex = content.substr(i + 1, 10);
                if (~/^\s*Tj/.match(afterHex)) {
                    if (needNewline && result.length > 0) {
                        result.add(divider);
                        needNewline = false;
                    }
                    var decoded = decodeHexStringWithToUnicode(hexContent, currentToUnicode);
                    if (decoded.length > 0) {
                        result.add(decoded);
                    }
                }
                i++;
                continue;
            }
            
            // Look for text string in parentheses
            if (c == 40) { // '('
                var textStart = i + 1;
                var depth = 1;
                i++;
                while (i < len && depth > 0) {
                    var cc = content.charCodeAt(i);
                    if (cc == 92) { // backslash escape
                        i += 2;
                        continue;
                    }
                    if (cc == 40) depth++;
                    if (cc == 41) depth--;
                    i++;
                }
                
                // Check if followed by Tj or '
                var afterStr = content.substr(i, 10);
                if (~/^\s*Tj/.match(afterStr) || ~/^\s*'/.match(afterStr)) {
                    if (needNewline && result.length > 0) {
                        result.add(divider);
                        needNewline = false;
                    }
                    var textContent = content.substr(textStart, i - textStart - 1);
                    var decoded = decodeTextStringWithToUnicode(textContent, currentToUnicode);
                    if (decoded.length > 0 && isPrintableText(decoded)) {
                        result.add(decoded);
                    }
                }
                continue;
            }
            
            i++;
        }
        
        return result.toString();
    }
    
    /**
     * Parse a TJ array and extract text with proper spacing
     * TJ arrays contain strings and numbers: [(Hello) -100 (World)]
     * Negative numbers indicate forward spacing, positive = backward
     */
    function parseTJArray(arrayContent:String, toUnicode:Map<Int, String>, fontSize:Float):String {
        var result = new StringBuf();
        var i = 0;
        var len = arrayContent.length;
        
        while (i < len) {
            // Skip whitespace
            while (i < len && isWhitespace(arrayContent.charCodeAt(i))) {
                i++;
            }
            if (i >= len) break;
            
            var c = arrayContent.charCodeAt(i);
            
            // Parse number (spacing adjustment)
            if (c == 45 || (c >= 48 && c <= 57)) { // '-' or digit
                var numStart = i;
                if (c == 45) i++;
                while (i < len) {
                    var nc = arrayContent.charCodeAt(i);
                    if ((nc >= 48 && nc <= 57) || nc == 46) { // digit or '.'
                        i++;
                    } else {
                        break;
                    }
                }
                var numStr = arrayContent.substr(numStart, i - numStart);
                var spacing = Std.parseFloat(numStr);
                if (spacing != null && !Math.isNaN(spacing)) {
                    // Large negative spacing typically means a space between words
                    // Threshold varies by font, but -100 to -200 is common for word space
                    if (spacing < -80) {
                        result.add(" ");
                    }
                }
                continue;
            }
            
            // Parse hex string
            if (c == 60) { // '<'
                var hexStart = i + 1;
                i++;
                while (i < len && arrayContent.charCodeAt(i) != 62) { // '>'
                    i++;
                }
                var hexContent = arrayContent.substr(hexStart, i - hexStart);
                var decoded = decodeHexStringWithToUnicode(hexContent, toUnicode);
                result.add(decoded);
                i++;
                continue;
            }
            
            // Parse string in parentheses
            if (c == 40) { // '('
                var textStart = i + 1;
                var depth = 1;
                i++;
                while (i < len && depth > 0) {
                    var cc = arrayContent.charCodeAt(i);
                    if (cc == 92) { i += 2; continue; } // escape
                    if (cc == 40) depth++;
                    if (cc == 41) depth--;
                    i++;
                }
                var textContent = arrayContent.substr(textStart, i - textStart - 1);
                var decoded = decodeTextStringWithToUnicode(textContent, toUnicode);
                if (isPrintableText(decoded)) {
                    result.add(decoded);
                }
                continue;
            }
            
            i++;
        }
        
        return result.toString();
    }
    
    function decodeHexStringWithToUnicode(hex:String, toUnicode:Map<Int, String>):String {
        // Remove whitespace
        hex = ~/\s/g.replace(hex, "");
        
        var result = new StringBuf();
        var i = 0;
        
        // Try 2-byte (4 hex chars) decoding first if we have ToUnicode
        if (toUnicode != null && hex.length >= 4) {
            while (i + 3 < hex.length) {
                var code = Std.parseInt("0x" + hex.substr(i, 4));
                if (code != null && toUnicode.exists(code)) {
                    result.add(toUnicode.get(code));
                    i += 4;
                } else {
                    // Fall back to single byte
                    var byte = Std.parseInt("0x" + hex.substr(i, 2));
                    if (byte != null) {
                        if (toUnicode != null && toUnicode.exists(byte)) {
                            result.add(toUnicode.get(byte));
                        } else if (byte >= 32 && byte < 127) {
                            result.addChar(byte);
                        }
                    }
                    i += 2;
                }
            }
        } else {
            // Simple byte-by-byte decoding
            while (i + 1 < hex.length) {
                var byte = Std.parseInt("0x" + hex.substr(i, 2));
                if (byte != null) {
                    if (toUnicode != null && toUnicode.exists(byte)) {
                        result.add(toUnicode.get(byte));
                    } else if (byte >= 32 && byte < 127) {
                        result.addChar(byte);
                    }
                }
                i += 2;
            }
        }
        
        return result.toString();
    }
    
    function decodeTextStringWithToUnicode(s:String, toUnicode:Map<Int, String>):String {
        var result = new StringBuf();
        var i = 0;
        while (i < s.length) {
            var c = s.charCodeAt(i);
            if (c == 92 && i + 1 < s.length) { // backslash
                var next = s.charCodeAt(i + 1);
                switch (next) {
                    case 110: result.addChar(10); i += 2; // \n
                    case 114: result.addChar(13); i += 2; // \r
                    case 116: result.addChar(9); i += 2;  // \t
                    case 40: result.addChar(40); i += 2;  // \(
                    case 41: result.addChar(41); i += 2;  // \)
                    case 92: result.addChar(92); i += 2;  // \\
                    default:
                        // Octal escape
                        if (next >= 48 && next <= 55) {
                            var octal = "";
                            var j = i + 1;
                            while (j < s.length && j < i + 4 && s.charCodeAt(j) >= 48 && s.charCodeAt(j) <= 55) {
                                octal += s.charAt(j);
                                j++;
                            }
                            var code = Std.parseInt("0o" + octal);
                            if (code != null) {
                                if (toUnicode != null && toUnicode.exists(code)) {
                                    result.add(toUnicode.get(code));
                                } else if (code >= 32 && code < 127) {
                                    result.addChar(code);
                                }
                            }
                            i = j;
                        } else {
                            result.addChar(next);
                            i += 2;
                        }
                }
            } else {
                if (toUnicode != null && toUnicode.exists(c)) {
                    result.add(toUnicode.get(c));
                } else if (c >= 32 && c < 127) {
                    result.addChar(c);
                }
                i++;
            }
        }
        return result.toString();
    }
    
    static function isWhitespace(c:Int):Bool {
        return c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32;
    }
    
    static function isDelimiter(c:Int):Bool {
        return c == 40 || c == 41 || c == 60 || c == 62 || c == 91 || c == 93 || c == 123 || c == 125 || c == 47 || c == 37;
    }
    
    /**
     * Parse Object Streams (ObjStm) to extract embedded objects
     */
    function parseObjectStreams() {
        var objStmStreams = new Array<{id:Int, bytes:Bytes, props:Map<String, Data>}>();
        
        // Collect all ObjStm streams
        for (id in objects.keys()) {
            var obj = objects.get(id);
            switch (obj) {
                case DStream(bytes, props):
                    var typeData = props.get("Type");
                    switch (typeData) {
                        case DName("ObjStm"):
                            objStmStreams.push({id: id, bytes: bytes, props: props});
                        default:
                    }
                default:
            }
        }
        
        for (stm in objStmStreams) {
            parseObjStmStream(stm.bytes, stm.props);
        }
    }
    
    /**
     * Parse a single Object Stream and extract embedded objects
     */
    function parseObjStmStream(bytes:Bytes, props:Map<String, Data>) {
        // Get N (number of objects) and First (byte offset of first object)
        var nData = props.get("N");
        var firstData = props.get("First");
        
        var n = switch(nData) { case DNumber(v): Std.int(v); default: 0; };
        var first = switch(firstData) { case DNumber(v): Std.int(v); default: 0; };
        
        if (n == 0 || first == 0) return;
        
        var content = bytes.toString();
        
        // Parse the header: pairs of object-id byte-offset
        var headerPart = content.substr(0, first);
        var objectPart = content.substr(first);
        
        // Parse object IDs and offsets from header
        var headerTokens = ~/\s+/g.split(StringTools.trim(headerPart));
        var objIds = new Array<Int>();
        var objOffsets = new Array<Int>();
        
        var i = 0;
        while (i + 1 < headerTokens.length) {
            objIds.push(Std.parseInt(headerTokens[i]));
            objOffsets.push(Std.parseInt(headerTokens[i + 1]));
            i += 2;
        }
        
        // For now, just store the raw object data - we'd need a full PDF parser to properly parse these
        // But we can look for specific patterns to extract Page and Font info
        for (j in 0...objIds.length) {
            var startOffset = objOffsets[j];
            var endOffset = (j + 1 < objOffsets.length) ? objOffsets[j + 1] : objectPart.length;
            var objContent = objectPart.substr(startOffset, endOffset - startOffset);
            
            // Check if this looks like a Page object
            if (objContent.indexOf("/Type /Page") >= 0 || objContent.indexOf("/Type/Page") >= 0) {
                // Create a simple DDict placeholder - we'll need to properly parse this
                var pageDict = new Map<String, Data>();
                pageDict.set("Type", DName("Page"));
                
                // Try to extract Contents reference
                var contentsMatch = ~/\/Contents\s+(\d+)\s+\d+\s+R/;
                if (contentsMatch.match(objContent)) {
                    var contentsId = Std.parseInt(contentsMatch.matched(1));
                    pageDict.set("Contents", DRef(contentsId, 0));
                }
                
                objects.set(objIds[j], DDict(pageDict));
            }
            
            // Check if this looks like a Font object
            if (objContent.indexOf("/Type /Font") >= 0 || objContent.indexOf("/Type/Font") >= 0) {
                var fontDict = new Map<String, Data>();
                fontDict.set("Type", DName("Font"));
                
                // Try to extract ToUnicode reference
                var tounicodeMatch = ~/\/ToUnicode\s+(\d+)\s+\d+\s+R/;
                if (tounicodeMatch.match(objContent)) {
                    var tounicodeId = Std.parseInt(tounicodeMatch.matched(1));
                    fontDict.set("ToUnicode", DRef(tounicodeId, 0));
                }
                
                objects.set(objIds[j], DDict(fontDict));
            }
        }
    }
    
    /**
     * Extract text from a content stream directly
     */
    function extractTextFromStream(bytes:Bytes):String {
        var result = new StringBuf();
        var content = bytes.toString();
        
        // Look for text between parentheses (Tj operator) or in TJ arrays
        var i = 0;
        var len = content.length;
        
        while (i < len) {
            var c = content.charCodeAt(i);
            
            // Look for text string in parentheses
            if (c == 40) { // '('
                var textStart = i + 1;
                var depth = 1;
                i++;
                while (i < len && depth > 0) {
                    c = content.charCodeAt(i);
                    if (c == 92) { // backslash escape
                        i += 2;
                        continue;
                    }
                    if (c == 40) depth++;
                    if (c == 41) depth--;
                    i++;
                }
                if (depth == 0) {
                    var textContent = content.substr(textStart, i - textStart - 1);
                    var decoded = decodeTextString(textContent);
                    if (decoded.length > 0 && isPrintableText(decoded)) {
                        result.add(decoded);
                    }
                }
                continue;
            }
            
            // Look for hex string
            if (c == 60 && i + 1 < len && content.charCodeAt(i + 1) != 60) { // '<' but not '<<'
                var hexStart = i + 1;
                i++;
                while (i < len && content.charCodeAt(i) != 62) { // '>'
                    i++;
                }
                var hexContent = content.substr(hexStart, i - hexStart);
                var decoded = decodeHexString(hexContent);
                if (decoded.length > 0 && isPrintableText(decoded)) {
                    result.add(decoded);
                }
                i++;
                continue;
            }
            
            i++;
        }
        
        return result.toString();
    }
    
    function decodeTextString(s:String):String {
        var result = new StringBuf();
        var i = 0;
        while (i < s.length) {
            var c = s.charCodeAt(i);
            if (c == 92 && i + 1 < s.length) { // backslash
                var next = s.charCodeAt(i + 1);
                switch (next) {
                    case 110: result.addChar(10); i += 2; // \n
                    case 114: result.addChar(13); i += 2; // \r
                    case 116: result.addChar(9); i += 2;  // \t
                    case 98: result.addChar(8); i += 2;   // \b
                    case 102: result.addChar(12); i += 2; // \f
                    case 40: result.addChar(40); i += 2;  // \(
                    case 41: result.addChar(41); i += 2;  // \)
                    case 92: result.addChar(92); i += 2;  // \\
                    default:
                        // Octal escape
                        if (next >= 48 && next <= 55) {
                            var octal = "";
                            var j = i + 1;
                            while (j < s.length && j < i + 4 && s.charCodeAt(j) >= 48 && s.charCodeAt(j) <= 55) {
                                octal += s.charAt(j);
                                j++;
                            }
                            result.addChar(Std.parseInt("0o" + octal));
                            i = j;
                        } else {
                            result.addChar(next);
                            i += 2;
                        }
                }
            } else {
                result.addChar(c);
                i++;
            }
        }
        return result.toString();
    }
    
    function decodeHexString(hex:String):String {
        // Remove whitespace
        hex = ~/\s/g.replace(hex, "");
        if (hex.length % 2 == 1) hex += "0";
        
        var result = new StringBuf();
        var i = 0;
        while (i + 1 < hex.length) {
            var byte = Std.parseInt("0x" + hex.substr(i, 2));
            if (byte != null) {
                result.addChar(byte);
            }
            i += 2;
        }
        return result.toString();
    }
    
    function isPrintableText(s:String):Bool {
        // Check if string contains mostly printable characters
        var printable = 0;
        for (i in 0...s.length) {
            var c = s.charCodeAt(i);
            if ((c >= 32 && c < 127) || c == 10 || c == 13 || c == 9) {
                printable++;
            }
        }
        return printable > s.length / 2;
    }

    /**
     * Build a lookup table of object ID -> Data
     */
    function buildObjectTable(data:Array<Data>) {
        for (obj in data) {
            switch (obj) {
                case DIndirect(id, rev, v):
                    objects.set(id, v);
                    // Also process nested indirect objects
                    processNestedObjects(v);
                default:
            }
        }
    }

    function processNestedObjects(data:Data) {
        switch (data) {
            case DIndirect(id, rev, v):
                objects.set(id, v);
                processNestedObjects(v);
            case DArray(arr):
                for (item in arr) {
                    processNestedObjects(item);
                }
            case DDict(props):
                for (key in props.keys()) {
                    processNestedObjects(props.get(key));
                }
            case DStream(bytes, props):
                for (key in props.keys()) {
                    processNestedObjects(props.get(key));
                }
            default:
        }
    }

    /**
     * Find and parse all font resources
     */
    function parseFonts() {
        for (id in objects.keys()) {
            var obj = objects.get(id);
            switch (obj) {
                case DDict(props):
                    var type = props.get("Type");
                    if (type != null) {
                        switch (type) {
                            case DName("Font"):
                                parseFont(id, props);
                            default:
                        }
                    }
                case DStream(bytes, props):
                    var type = props.get("Type");
                    if (type != null) {
                        switch (type) {
                            case DName("Font"):
                                parseFont(id, props);
                            default:
                        }
                    }
                default:
            }
        }
    }

    /**
     * Parse a font dictionary and extract encoding information
     */
    function parseFont(id:Int, props:Map<String, Data>) {
        var fontInfo = new FontInfo();
        
        // Get font name
        var baseFont = props.get("BaseFont");
        if (baseFont != null) {
            switch (baseFont) {
                case DName(name):
                    fontInfo.name = name;
                    log("Parsing font: " + name);
                default:
            }
        }
        
        // Get encoding
        var encoding = props.get("Encoding");
        if (encoding != null) {
            switch (encoding) {
                case DName(name):
                    fontInfo.encodingName = name;
                    fontInfo.encoding = getStandardEncoding(name);
                    log("  Encoding: " + name);
                case DDict(encProps):
                    // Custom encoding dictionary
                    fontInfo.encoding = parseEncodingDict(encProps);
                    log("  Encoding: custom dict");
                case DRef(refId, rev):
                    var encObj = resolveRef(refId);
                    if (encObj != null) {
                        switch (encObj) {
                            case DDict(encProps):
                                fontInfo.encoding = parseEncodingDict(encProps);
                                log("  Encoding: ref to dict");
                            default:
                        }
                    }
                default:
            }
        }
        
        // Get ToUnicode CMap (most important for proper decoding)
        var toUnicode = props.get("ToUnicode");
        if (toUnicode != null) {
            var cmapBytes = getCMapBytes(toUnicode);
            if (cmapBytes != null) {
                fontInfo.toUnicode = CMapParser.parse(cmapBytes);
                var count = 0;
                var sampleMappings = "";
                for (k in fontInfo.toUnicode.keys()) {
                    count++;
                    if (count <= 10) {
                        sampleMappings += " " + StringTools.hex(k, 4) + "->" + fontInfo.toUnicode.get(k);
                    }
                }
                log("  ToUnicode CMap: " + count + " mappings");
                log("  Sample:" + sampleMappings);
            }
        }
        
        // If no ToUnicode or incomplete, try to parse embedded font program
        var toUnicodeCount = 0;
        if (fontInfo.toUnicode != null) {
            for (_ in fontInfo.toUnicode) toUnicodeCount++;
        }
        if (toUnicodeCount < 100) { // If ToUnicode has fewer than 100 mappings, also try embedded font
            log("  ToUnicode incomplete (" + toUnicodeCount + " mappings), trying embedded font...");
            parseEmbeddedFont(props, fontInfo);
        }
        
        // Store font info
        fonts.set("F" + id, fontInfo);
        
        // Also try to find font reference names in resource dictionaries
        storeFontByName(id, fontInfo);
    }
    
    /**
     * Try to find and parse an embedded font program to get glyph mappings
     */
    function parseEmbeddedFont(props:Map<String, Data>, fontInfo:FontInfo) {
        // Get FontDescriptor
        var fontDescriptor = props.get("FontDescriptor");
        var descendantProps:Map<String, Data> = null;
        
        if (fontDescriptor == null) {
            // Check for DescendantFonts (CIDFont case)
            var descendants = props.get("DescendantFonts");
            if (descendants != null) {
                log("  Looking in DescendantFonts...");
                descendants = resolveIfRef(descendants);
                switch (descendants) {
                    case DArray(arr):
                        if (arr.length > 0) {
                            var descendant = resolveIfRef(arr[0]);
                            switch (descendant) {
                                case DDict(dProps):
                                    fontDescriptor = dProps.get("FontDescriptor");
                                    descendantProps = dProps;
                                    log("  Found FontDescriptor in descendant");
                                    
                                    // Check for CIDToGIDMap
                                    var cidToGid = dProps.get("CIDToGIDMap");
                                    if (cidToGid != null) {
                                        log("  Found CIDToGIDMap!");
                                        parseCIDToGIDMap(cidToGid, fontInfo);
                                    }
                                default:
                            }
                        }
                    default:
                }
            }
        }
        
        if (fontDescriptor == null) {
            log("  No FontDescriptor found");
            return;
        }
        
        fontDescriptor = resolveIfRef(fontDescriptor);
        
        var fdProps:Map<String, Data> = null;
        switch (fontDescriptor) {
            case DDict(p):
                fdProps = p;
            default:
                log("  FontDescriptor is not a dict");
                return;
        }
        
        // Look for FontFile, FontFile2 (TrueType), or FontFile3 (CFF/OpenType)
        var fontFile = fdProps.get("FontFile2"); // TrueType
        var fontType = "FontFile2";
        if (fontFile == null) {
            fontFile = fdProps.get("FontFile3"); // CFF/OpenType
            fontType = "FontFile3";
        }
        if (fontFile == null) {
            fontFile = fdProps.get("FontFile"); // Type 1
            fontType = "FontFile";
        }
        
        if (fontFile == null) {
            log("  No embedded font file found");
            return;
        }
        
        log("  Found " + fontType);
        
        // Get the font program bytes
        var fontBytes = getFontBytes(fontFile);
        if (fontBytes == null || fontBytes.length < 12) {
            log("  Font bytes null or too small");
            return;
        }
        
        log("  Font data: " + fontBytes.length + " bytes");
        
        // Parse the font using FontParser
        var parser = new FontParser();
        if (parser.parse(fontBytes)) {
            fontInfo.fontParser = parser;
            log("  FontParser: " + parser.getStats());
            
            // Show sample glyph mappings from FontParser
            var sampleFP = "";
            var fpCount = 0;
            for (gid in parser.glyphToUnicode.keys()) {
                fpCount++;
                if (fpCount <= 10) {
                    var ucp = parser.glyphToUnicode.get(gid);
                    sampleFP += " " + StringTools.hex(gid, 4) + "->" + CMapParser.codePointToUtf8(ucp);
                }
            }
            log("  FontParser sample:" + sampleFP);
            
            // Also convert glyph mappings to toUnicode format for compatibility
            if (fontInfo.toUnicode == null) {
                fontInfo.toUnicode = new Map<Int, String>();
            }
            for (glyphId in parser.glyphToUnicode.keys()) {
                var unicode = parser.glyphToUnicode.get(glyphId);
                if (unicode > 0 && !fontInfo.toUnicode.exists(glyphId)) {
                    fontInfo.toUnicode.set(glyphId, CMapParser.codePointToUtf8(unicode));
                }
            }
        } else {
            log("  FontParser.parse() returned false");
        }
    }
    
    /**
     * Get font program bytes from a FontFile reference
     */
    function getFontBytes(fontFile:Data):Bytes {
        switch (fontFile) {
            case DRef(id, rev):
                var obj = resolveRef(id);
                return getFontBytes(obj);
            case DStream(bytes, props):
                return bytes;
            default:
                return null;
        }
    }
    
    /**
     * Parse CIDToGIDMap to get mapping from CID to glyph ID.
     * This is crucial for subset fonts where CIDs don't map directly to glyph IDs.
     */
    function parseCIDToGIDMap(cidToGid:Data, fontInfo:FontInfo) {
        switch (cidToGid) {
            case DName("Identity"):
                log("  CIDToGIDMap is Identity (CID = GID)");
                // Identity mapping - CID equals GID, no conversion needed
            case DRef(id, rev):
                var obj = resolveRef(id);
                parseCIDToGIDMap(obj, fontInfo);
            case DStream(bytes, props):
                log("  CIDToGIDMap stream: " + bytes.length + " bytes");
                // The stream contains pairs of 2-byte values: for each CID (0, 1, 2...), 
                // the corresponding GID is at position CID*2
                // This allows us to convert CID -> GID -> Unicode
                if (fontInfo.fontParser != null && bytes.length >= 2) {
                    var newToUnicode = new Map<Int, String>();
                    var mappedCount = 0;
                    
                    // For each CID, look up the GID and then the Unicode
                    var numCIDs = Std.int(bytes.length / 2);
                    for (cid in 0...numCIDs) {
                        var gid = (bytes.get(cid * 2) << 8) | bytes.get(cid * 2 + 1);
                        if (gid > 0) {
                            var unicode = fontInfo.fontParser.getUnicodeForGlyph(gid);
                            if (unicode > 0) {
                                newToUnicode.set(cid, CMapParser.codePointToUtf8(unicode));
                                mappedCount++;
                            }
                        }
                    }
                    
                    log("  CIDToGIDMap resolved " + mappedCount + " CID->Unicode mappings");
                    
                    // Add these to the font's toUnicode map
                    if (fontInfo.toUnicode == null) {
                        fontInfo.toUnicode = new Map<Int, String>();
                    }
                    for (cid in newToUnicode.keys()) {
                        if (!fontInfo.toUnicode.exists(cid)) {
                            fontInfo.toUnicode.set(cid, newToUnicode.get(cid));
                        }
                    }
                }
            default:
        }
    }

    function storeFontByName(id:Int, fontInfo:FontInfo) {
        // Search for Font resource entries that reference this font
        for (objId in objects.keys()) {
            var obj = objects.get(objId);
            switch (obj) {
                case DDict(props):
                    var fontRes = props.get("Font");
                    if (fontRes != null) {
                        switch (fontRes) {
                            case DDict(fontDict):
                                for (fontName in fontDict.keys()) {
                                    var fontRef = fontDict.get(fontName);
                                    switch (fontRef) {
                                        case DRef(refId, rev):
                                            if (refId == id) {
                                                fonts.set(fontName, fontInfo);
                                            }
                                        default:
                                    }
                                }
                            default:
                        }
                    }
                default:
            }
        }
    }

    function getCMapBytes(toUnicode:Data):Bytes {
        switch (toUnicode) {
            case DRef(id, rev):
                var obj = resolveRef(id);
                return getCMapBytes(obj);
            case DStream(bytes, props):
                return bytes;
            default:
                return null;
        }
    }

    function parseEncodingDict(props:Map<String, Data>):Map<Int, Int> {
        var encoding = new Map<Int, Int>();
        
        // Start with base encoding if specified
        var baseEnc = props.get("BaseEncoding");
        if (baseEnc != null) {
            switch (baseEnc) {
                case DName(name):
                    var base = getStandardEncoding(name);
                    if (base != null) {
                        for (k in base.keys()) {
                            encoding.set(k, base.get(k));
                        }
                    }
                default:
            }
        }
        
        // Apply differences
        var diff = props.get("Differences");
        if (diff != null) {
            switch (diff) {
                case DArray(arr):
                    var code = 0;
                    for (item in arr) {
                        switch (item) {
                            case DNumber(n):
                                code = Std.int(n);
                            case DName(name):
                                var unicode = glyphNameToUnicode(name);
                                if (unicode != -1) {
                                    encoding.set(code, unicode);
                                }
                                code++;
                            default:
                        }
                    }
                default:
            }
        }
        
        return encoding;
    }

    function getStandardEncoding(name:String):Map<Int, Int> {
        var encoding = new Map<Int, Int>();
        
        if (name == "WinAnsiEncoding") {
            // Windows ANSI (CP1252) - common encoding
            for (i in 32...127) {
                encoding.set(i, i);
            }
            // Extended characters
            encoding.set(128, 0x20AC); // Euro
            encoding.set(130, 0x201A); // Single low quote
            encoding.set(131, 0x0192); // f with hook
            encoding.set(132, 0x201E); // Double low quote
            encoding.set(133, 0x2026); // Ellipsis
            encoding.set(134, 0x2020); // Dagger
            encoding.set(135, 0x2021); // Double dagger
            encoding.set(136, 0x02C6); // Circumflex
            encoding.set(137, 0x2030); // Per mille
            encoding.set(138, 0x0160); // S caron
            encoding.set(139, 0x2039); // Single left angle quote
            encoding.set(140, 0x0152); // OE ligature
            encoding.set(142, 0x017D); // Z caron
            encoding.set(145, 0x2018); // Left single quote
            encoding.set(146, 0x2019); // Right single quote
            encoding.set(147, 0x201C); // Left double quote
            encoding.set(148, 0x201D); // Right double quote
            encoding.set(149, 0x2022); // Bullet
            encoding.set(150, 0x2013); // En dash
            encoding.set(151, 0x2014); // Em dash
            encoding.set(152, 0x02DC); // Tilde
            encoding.set(153, 0x2122); // Trademark
            encoding.set(154, 0x0161); // s caron
            encoding.set(155, 0x203A); // Single right angle quote
            encoding.set(156, 0x0153); // oe ligature
            encoding.set(158, 0x017E); // z caron
            encoding.set(159, 0x0178); // Y diaeresis
            for (i in 160...256) {
                encoding.set(i, i);
            }
        } else if (name == "MacRomanEncoding") {
            for (i in 32...127) {
                encoding.set(i, i);
            }
            // Add Mac Roman extended characters as needed
        } else if (name == "StandardEncoding" || name == "Identity-H" || name == "Identity-V") {
            // Identity or standard - direct mapping
            for (i in 0...256) {
                encoding.set(i, i);
            }
        }
        
        return encoding;
    }

    function glyphNameToUnicode(name:String):Int {
        // Common glyph name to Unicode mappings
        var glyphMap = [
            "space" => 0x0020, "exclam" => 0x0021, "quotedbl" => 0x0022, "numbersign" => 0x0023,
            "dollar" => 0x0024, "percent" => 0x0025, "ampersand" => 0x0026, "quotesingle" => 0x0027,
            "parenleft" => 0x0028, "parenright" => 0x0029, "asterisk" => 0x002A, "plus" => 0x002B,
            "comma" => 0x002C, "hyphen" => 0x002D, "period" => 0x002E, "slash" => 0x002F,
            "zero" => 0x0030, "one" => 0x0031, "two" => 0x0032, "three" => 0x0033,
            "four" => 0x0034, "five" => 0x0035, "six" => 0x0036, "seven" => 0x0037,
            "eight" => 0x0038, "nine" => 0x0039, "colon" => 0x003A, "semicolon" => 0x003B,
            "less" => 0x003C, "equal" => 0x003D, "greater" => 0x003E, "question" => 0x003F,
            "at" => 0x0040, "A" => 0x0041, "B" => 0x0042, "C" => 0x0043, "D" => 0x0044,
            "E" => 0x0045, "F" => 0x0046, "G" => 0x0047, "H" => 0x0048, "I" => 0x0049,
            "J" => 0x004A, "K" => 0x004B, "L" => 0x004C, "M" => 0x004D, "N" => 0x004E,
            "O" => 0x004F, "P" => 0x0050, "Q" => 0x0051, "R" => 0x0052, "S" => 0x0053,
            "T" => 0x0054, "U" => 0x0055, "V" => 0x0056, "W" => 0x0057, "X" => 0x0058,
            "Y" => 0x0059, "Z" => 0x005A, "bracketleft" => 0x005B, "backslash" => 0x005C,
            "bracketright" => 0x005D, "asciicircum" => 0x005E, "underscore" => 0x005F,
            "grave" => 0x0060, "a" => 0x0061, "b" => 0x0062, "c" => 0x0063, "d" => 0x0064,
            "e" => 0x0065, "f" => 0x0066, "g" => 0x0067, "h" => 0x0068, "i" => 0x0069,
            "j" => 0x006A, "k" => 0x006B, "l" => 0x006C, "m" => 0x006D, "n" => 0x006E,
            "o" => 0x006F, "p" => 0x0070, "q" => 0x0071, "r" => 0x0072, "s" => 0x0073,
            "t" => 0x0074, "u" => 0x0075, "v" => 0x0076, "w" => 0x0077, "x" => 0x0078,
            "y" => 0x0079, "z" => 0x007A, "braceleft" => 0x007B, "bar" => 0x007C,
            "braceright" => 0x007D, "asciitilde" => 0x007E
        ];
        
        if (glyphMap.exists(name)) {
            return glyphMap.get(name);
        }
        
        // Try uni#### format
        if (name.length == 7 && name.substr(0, 3) == "uni") {
            var hex = name.substr(3);
            return Std.parseInt("0x" + hex);
        }
        
        return -1;
    }

    function resolveRef(id:Int):Data {
        return objects.get(id);
    }

    /**
     * Find all page objects
     */
    function findPages():Array<Int> {
        var pages = new Array<Int>();
        
        for (id in objects.keys()) {
            var obj = objects.get(id);
            switch (obj) {
                case DDict(props):
                    var type = props.get("Type");
                    if (type != null) {
                        switch (type) {
                            case DName("Page"):
                                pages.push(id);
                            default:
                        }
                    }
                default:
            }
        }
        
        return pages;
    }

    /**
     * Extract text from a single page
     */
    function extractPageText(pageId:Int):String {
        var pageObj = objects.get(pageId);
        if (pageObj == null) {
            return "";
        }
        
        var result = new StringBuf();
        
        switch (pageObj) {
            case DDict(props):
                // Get page resources (fonts, etc.)
                var resources = getResources(props);
                
                // Get content stream(s)
                var contents = props.get("Contents");
                if (contents != null) {
                    var streams = getContentStreams(contents);
                    for (stream in streams) {
                        var text = parseContentStream(stream, resources);
                        result.add(text);                      
                    }
                }
            default:
        }
        
        return result.toString();
    }

    function getResources(pageProps:Map<String, Data>):Map<String, FontInfo> {
        var pageFonts = new Map<String, FontInfo>();
        
        var resources = pageProps.get("Resources");
        if (resources != null) {
            resources = resolveIfRef(resources);
            switch (resources) {
                case DDict(resProps):
                    var fontRes = resProps.get("Font");
                    if (fontRes != null) {
                        fontRes = resolveIfRef(fontRes);
                        switch (fontRes) {
                            case DDict(fontDict):
                                for (fontName in fontDict.keys()) {
                                    var fontRef = fontDict.get(fontName);
                                    switch (fontRef) {
                                        case DRef(id, rev):
                                            // Look up the font info
                                            if (fonts.exists(fontName)) {
                                                pageFonts.set(fontName, fonts.get(fontName));
                                            } else {
                                                // Parse font on demand
                                                var fontObj = resolveRef(id);
                                                if (fontObj != null) {
                                                    switch (fontObj) {
                                                        case DDict(fProps):
                                                            parseFont(id, fProps);
                                                            if (fonts.exists(fontName)) {
                                                                pageFonts.set(fontName, fonts.get(fontName));
                                                            }
                                                        case DStream(bytes, fProps):
                                                            parseFont(id, fProps);
                                                            if (fonts.exists(fontName)) {
                                                                pageFonts.set(fontName, fonts.get(fontName));
                                                            }
                                                        default:
                                                    }
                                                }
                                            }
                                        default:
                                    }
                                }
                            default:
                        }
                    }
                default:
            }
        }
        
        return pageFonts;
    }

    function resolveIfRef(data:Data):Data {
        switch (data) {
            case DRef(id, rev):
                return resolveRef(id);
            default:
                return data;
        }
    }

    function getContentStreams(contents:Data):Array<Bytes> {
        var streams = new Array<Bytes>();
        
        switch (contents) {
            case DRef(id, rev):
                var obj = resolveRef(id);
                if (obj != null) {
                    return getContentStreams(obj);
                }
            case DStream(bytes, props):
                streams.push(bytes);
            case DArray(arr):
                for (item in arr) {
                    var subStreams = getContentStreams(item);
                    for (s in subStreams) {
                        streams.push(s);
                    }
                }
            default:
        }
        
        return streams;
    }

    /**
     * Parse a content stream and extract text
     */
    function parseContentStream(stream:Bytes, pageFonts:Map<String, FontInfo>):String {
        return ContentStreamParser.extractText(stream, pageFonts, fonts);
    }
}

/**
 * Stores font information including encoding and ToUnicode mapping
 */
class FontInfo {
    public var name:String;
    public var encodingName:String;
    public var encoding:Map<Int, Int>;
    public var toUnicode:Map<Int, String>;
    public var fontParser:FontParser; // Parsed embedded font program

    public function new() {
        name = "";
        encodingName = "";
        encoding = new Map();
        toUnicode = new Map();
        fontParser = null;
    }

    /**
     * Decode a character code to Unicode string
     */
    public function decode(charCode:Int):String {
        // First try ToUnicode map (most accurate)
        if (toUnicode != null && toUnicode.exists(charCode)) {
            return toUnicode.get(charCode);
        }
        
        // Then try embedded font parser (glyph ID to Unicode)
        if (fontParser != null) {
            var unicode = fontParser.getUnicodeForGlyph(charCode);
            if (unicode > 0) {
                return CMapParser.codePointToUtf8(unicode);
            }
        }
        
        // Then try encoding map
        if (encoding != null && encoding.exists(charCode)) {
            var unicode = encoding.get(charCode);
            return CMapParser.codePointToUtf8(unicode);
        }
        
        // Fall back to direct mapping for printable ASCII
        if (charCode >= 32 && charCode < 127) {
            return CMapParser.codePointToUtf8(charCode);
        }
        
        return "";
    }

    /**
     * Decode bytes to string using this font's encoding
     */
    public function decodeBytes(bytes:Bytes, offset:Int, length:Int):String {
        var result = new StringBuf();
        var i = offset;
        var end = offset + length;
        
        while (i < end) {
            var charCode = bytes.get(i);
            
            // Check if this might be a 2-byte character (for CID fonts)
            if (toUnicode != null && i + 1 < end) {
                var twoByteCode = (charCode << 8) | bytes.get(i + 1);
                if (toUnicode.exists(twoByteCode)) {
                    result.add(toUnicode.get(twoByteCode));
                    i += 2;
                    continue;
                }
            }
            
            result.add(decode(charCode));
            i++;
        }
        
        return result.toString();
    }
}
