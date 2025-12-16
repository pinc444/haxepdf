package;

class PdfToText {
    static function main() {
        var filePath = Sys.args()[0];
        var reader = new format.pdf.Reader();
        var file = sys.io.File.read(filePath);
        var pdfData = reader.read(file);
        var extractor = new format.pdf.TextExtractor();
        var text = extractor.extractText(pdfData);
        Sys.println(text);
    }
}