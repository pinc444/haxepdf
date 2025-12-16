package;

import format.pdf.Reader;
import format.pdf.TextExtractor;
import sys.io.File;

class Main {
    public static function main() {
        trace("=== PDF Text Extractor ===\n");
        
        // Read the PDF file
        var file = File.read("file.pdf");
        var reader = new Reader();
        var pdfData = reader.read(file);
        file.close();
        
        // Use the new TextExtractor for proper font decoding
        var extractor = new TextExtractor();
        var fullText = extractor.extractText(pdfData);
        
        trace("=== Extracted Text ===");
        Sys.println(fullText);
        trace(fullText);
        
        // Search for PO number patterns
        trace("\n=== Searching for PO Number ===");
        findPONumber(fullText);
    }

    static function findPONumber(text:String) {
        // Common PO number patterns - capture PO number format
        var patterns = [
            ~/P\.?O\.?\s*No\.?\s*:?\s*(PO[\-]?[0-9]+)/i,  // P.O. No. PO-1234
            ~/P\.?O\.?\s*No\.?\s*:?\s*([0-9]{4,})/i,     // P.O. No. 12345
            ~/PO\s*#\s*:?\s*([A-Z0-9\-]{4,})/i,
            ~/P\.?O\.?\s*#\s*:?\s*([A-Z0-9\-]{4,})/i,
            ~/Purchase\s*Order\s*[#:]?\s*([A-Z0-9\-]{4,})/i,
            ~/Order\s*[#:]\s*([A-Z0-9\-]{4,})/i,
            ~/PO\s*Number\s*:?\s*([A-Z0-9\-]{4,})/i,
            ~/PO:\s*([A-Z0-9\-]{4,})/i,
            ~/PO\s+([0-9]{5,})/i,
            ~/\bPO[\-]?([0-9]{4,})\b/i
        ];

        var found = false;
        for (pattern in patterns) {
            if (pattern.match(text)) {
                var poNumber = pattern.matched(1);
                // Clean up the PO number - take only valid portion
                var cleaned = cleanPONumber(poNumber);
                trace("Found PO Number: " + cleaned);
                found = true;
                break;  // Stop after first match
            }
        }
        
        if (!found) {
            trace("No PO number pattern found in extracted text.");
            trace("Tip: Check the extracted text above for the format of PO numbers in your PDF.");
        }
    }
    
    static function cleanPONumber(po:String):String {
        // Extract just the PO number portion (letters, digits, and hyphen)
        // Stop at lowercase letter following digits (e.g., "PO-47655Project" -> "PO-4765")
        var result = new StringBuf();
        var i = 0;
        var sawDigit = false;
        while (i < po.length) {
            var c = po.charAt(i);
            var code = po.charCodeAt(i);
            
            if (code >= 48 && code <= 57) { // 0-9
                result.add(c);
                sawDigit = true;
            } else if (code >= 65 && code <= 90) { // A-Z
                result.add(c);
            } else if (c == "-") {
                result.add(c);
            } else if (code >= 97 && code <= 122 && sawDigit) { // a-z after digit = stop
                break;
            }
            i++;
        }
        return result.toString();
    }
}