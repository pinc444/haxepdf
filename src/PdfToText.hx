package;

class PdfToText {
    static function main() {
        try {
            var filePath = Sys.args()[0];
            var debug = Sys.args().length > 1 && Sys.args()[1] == "-d";
            var outputFile = Sys.args().length > 2 ? Sys.args()[2] : null;
            
            var reader = new format.pdf.Reader();
            var file = sys.io.File.read(filePath);
            var pdfData = reader.read(file);
            var extractor = new format.pdf.TextExtractor(' '); // Use space as divider
            
            if (debug) {
                extractor.setDebug(true);
            }
            
            var text = extractor.extractText(pdfData);
            
            if (outputFile != null) {
                // Write to file with UTF-8 BOM for proper Unicode support
                var out = sys.io.File.write(outputFile);
                // Write UTF-8 BOM
                out.writeByte(0xEF);
                out.writeByte(0xBB);
                out.writeByte(0xBF);
                out.writeString(text);
                out.close();
                Sys.println("Output written to: " + outputFile);
            } else {
                Sys.println(text);
            }
        } catch (e:Dynamic) {
            Sys.println("Error: " + Std.string(e));
            Sys.exit(1);
        }
    }
}