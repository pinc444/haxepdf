package;

class PdfToText {
    static function main() {
        try {
            var filePath = Sys.args()[0];
            var debug = Sys.args().length > 1 && Sys.args()[1] == "-d";
            
            var reader = new format.pdf.Reader();
            var file = sys.io.File.read(filePath);
            var pdfData = reader.read(file);
            var extractor = new format.pdf.TextExtractor(' '); // Use space as divider
            
            if (debug) {
                extractor.setDebug(true);
            }
            
            var text = extractor.extractText(pdfData);
            Sys.println(text);
        } catch (e:Dynamic) {
            Sys.println("Error: " + Std.string(e));
            Sys.exit(1);
        }
    }
}