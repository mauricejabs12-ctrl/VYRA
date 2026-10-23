import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// ---------------------------------------------------------------- PowerPoint (.pptx) ohne Office: modernes, schlichtes Folienlayout
public final class SlideData {
    public var title = ""
    public var bullets = [String]()
    public var notes = ""
    public init(_ title: String = "", _ bullets: [String] = []) { self.title = title; self.bullets = bullets }
}
public enum PptxWriter {
    static func x(_ s: String) -> String { HTMLEntities.xml(s) }
    static let w: Int64 = 12192000, h: Int64 = 6858000 // 16:9
    public static func fromMarkdown(_ md: String) -> [SlideData] {
        var list = [SlideData]()
        var cur: SlideData?
        for b in MdBlocks.parse(md) {
            if b.kind == "h" && b.level <= 3 { let s = SlideData(MdBlocks.plain(b.text)); cur = s; list.append(s); continue }
            if cur == nil { let s = SlideData("Überblick"); cur = s; list.append(s) }
            guard let c = cur else { continue }
            if b.kind == "ul" || b.kind == "ol" { for it in b.items { c.bullets.append(MdBlocks.plain(it)) } }
            else if b.kind == "table" { for r in b.rows { c.bullets.append(r.joined(separator: "  ·  ")) } }
            else if b.kind == "p" || b.kind == "quote" || b.kind == "h" {
                let t = MdBlocks.plain(b.text)
                for s in Rx.split(t, "(?<=[.!?])\\s+(?=[A-ZÄÖÜ])") where !s.trimmed.isEmpty { c.bullets.append(s.trimmed) }
            } else if b.kind == "code" { c.bullets.append(b.text.splitKeep("\n")[0]) }
        }
        // Lange Folien teilen (hoechstens 7 Punkte)
        var outp = [SlideData]()
        for s in list {
            if s.bullets.count <= 7 { outp.append(s); continue }
            var i = 0
            while i < s.bullets.count { outp.append(SlideData(s.title + (i > 0 ? " (Forts.)" : ""), Array(s.bullets[i..<min(i + 6, s.bullets.count)]))); i += 6 }
        }
        return outp
    }
    static func sp(_ id: Int, _ name: String, _ x0: Int64, _ y: Int64, _ cx: Int64, _ cy: Int64, _ body: String) -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"\(x0)\" y=\"\(y)\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr wrap=\"square\" lIns=\"0\" tIns=\"0\" rIns=\"0\" bIns=\"0\"><a:normAutofit/></a:bodyPr><a:lstStyle/>" + body + "</p:txBody></p:sp>"
    }
    static func rect(_ id: Int, _ x0: Int64, _ y: Int64, _ cx: Int64, _ cy: Int64, _ color: String) -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"Akzent\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"\(x0)\" y=\"\(y)\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"roundRect\"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val=\"\(color)\"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr></p:sp>"
    }
    static func para(_ text: String, _ size: Int, _ bold: Bool, _ color: String, _ bullet: Bool) -> String {
        var sb = "<a:p><a:pPr"
        if bullet { sb += " marL=\"342900\" indent=\"-342900\"><a:spcBef><a:spcPts val=\"900\"/></a:spcBef><a:buClr><a:srgbClr val=\"7C83FF\"/></a:buClr><a:buFont typeface=\"Arial\"/><a:buChar char=\"•\"/></a:pPr>" }
        else { sb += "><a:buNone/></a:pPr>" }
        for r in MdBlocks.runs(text) {
            sb += "<a:r><a:rPr lang=\"de-DE\" sz=\"\(size)\"" + (bold || r.1 ? " b=\"1\"" : "") + " dirty=\"0\"><a:solidFill><a:srgbClr val=\"" + color + "\"/></a:solidFill><a:latin typeface=\"Segoe UI\"/></a:rPr><a:t>" + x(r.0) + "</a:t></a:r>"
        }
        return sb + "</a:p>"
    }
    static func slideXml(_ shapes: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><p:sld xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"15161A\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>" + shapes + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
    }
    public static func write(_ path: String, _ title: String, _ slides: [SlideData], _ subtitle: String?) throws {
        var all = [String]()
        // Titelfolie
        all.append(slideXml(rect(2, 914400, 2560320, 914400, 73152, "7C83FF") + sp(3, "Titel", 914400, 2743200, 10363200, 1371600, para(title, 4400, true, "F3F4F8", false)) + sp(4, "Untertitel", 914400, 4206240, 10363200, 640080, para(subtitle ?? "", 1800, false, "A4A8B8", false))))
        var n = 1
        for s in slides {
            n += 1
            var body = ""
            for b in s.bullets.prefix(8) { body += para(b, s.bullets.count > 5 ? 1800 : 2000, false, "D9DBE4", true) }
            if body.isEmpty { body = para("", 2000, false, "D9DBE4", false) }
            let shapes = rect(2, 685800, 640080, 54864, 548640, "7C83FF") + sp(3, "Titel", 868680, 548640, 10515600, 731520, para(s.title, 3000, true, "F3F4F8", false)) + sp(4, "Inhalt", 868680, 1554480, 10515600, 4754880, body) + sp(5, "Nummer", 10881360, 6217920, 640080, 320040, "<a:p><a:pPr algn=\"r\"/><a:r><a:rPr lang=\"de-DE\" sz=\"1100\"><a:solidFill><a:srgbClr val=\"6B6F80\"/></a:solidFill></a:rPr><a:t>\(n)</a:t></a:r></a:p>")
            all.append(slideXml(shapes))
        }
        let zip = try ZipWriter(path)
        let hdr = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
        let relNs = "http://schemas.openxmlformats.org/package/2006/relationships", rt = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        var ct = hdr + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/><Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/><Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/><Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/><Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
        for i in 0..<all.count { ct += "<Override PartName=\"/ppt/slides/slide\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>" }
        try zip.add("[Content_Types].xml", text: ct + "</Types>")
        try zip.add("_rels/.rels", text: hdr + "<Relationships xmlns=\"" + relNs + "\"><Relationship Id=\"rId1\" Type=\"" + rt + "officeDocument\" Target=\"ppt/presentation.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/></Relationships>")
        try zip.add("docProps/core.xml", text: hdr + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><dc:title>" + x(title) + "</dc:title><dc:creator>VYRA KI</dc:creator><dcterms:created xsi:type=\"dcterms:W3CDTF\">" + DE.stamp(Date(), "yyyy-MM-dd'T'HH:mm:ss'Z'") + "</dcterms:created></cp:coreProperties>")
        var pres = hdr + "<p:presentation " + ns + " saveSubsetFonts=\"1\"><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>"
        var prel = hdr + "<Relationships xmlns=\"" + relNs + "\"><Relationship Id=\"rId1\" Type=\"" + rt + "slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/><Relationship Id=\"rId2\" Type=\"" + rt + "theme\" Target=\"theme/theme1.xml\"/>"
        for i in 0..<all.count {
            pres += "<p:sldId id=\"\(256 + i)\" r:id=\"rId\(10 + i)\"/>"
            prel += "<Relationship Id=\"rId\(10 + i)\" Type=\"" + rt + "slide\" Target=\"slides/slide\(i + 1).xml\"/>"
        }
        pres += "</p:sldIdLst><p:sldSz cx=\"\(w)\" cy=\"\(h)\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>"
        try zip.add("ppt/presentation.xml", text: pres)
        try zip.add("ppt/_rels/presentation.xml.rels", text: prel + "</Relationships>")
        let emptyTree = "<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr></p:spTree>"
        try zip.add("ppt/slideMasters/slideMaster1.xml", text: hdr + "<p:sldMaster " + ns + "><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"15161A\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>" + emptyTree + "</p:cSld><p:clrMap bg1=\"dk1\" tx1=\"lt1\" bg2=\"dk2\" tx2=\"lt2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz=\"3200\"/></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr><a:defRPr sz=\"2000\"/></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:lvl1pPr><a:defRPr sz=\"1800\"/></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>")
        try zip.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", text: hdr + "<Relationships xmlns=\"" + relNs + "\"><Relationship Id=\"rId1\" Type=\"" + rt + "slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/><Relationship Id=\"rId2\" Type=\"" + rt + "theme\" Target=\"../theme/theme1.xml\"/></Relationships>")
        try zip.add("ppt/slideLayouts/slideLayout1.xml", text: hdr + "<p:sldLayout " + ns + " type=\"blank\" preserve=\"1\"><p:cSld name=\"Leer\">" + emptyTree + "</p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")
        try zip.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", text: hdr + "<Relationships xmlns=\"" + relNs + "\"><Relationship Id=\"rId1\" Type=\"" + rt + "slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>")
        try zip.add("ppt/theme/theme1.xml", text: theme)
        for i in 0..<all.count {
            try zip.add("ppt/slides/slide\(i + 1).xml", text: all[i])
            try zip.add("ppt/slides/_rels/slide\(i + 1).xml.rels", text: hdr + "<Relationships xmlns=\"" + relNs + "\"><Relationship Id=\"rId1\" Type=\"" + rt + "slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/></Relationships>")
        }
        try zip.close()
    }
    static let theme = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"VYRA\"><a:themeElements><a:clrScheme name=\"VYRA\"><a:dk1><a:srgbClr val=\"15161A\"/></a:dk1><a:lt1><a:srgbClr val=\"F3F4F8\"/></a:lt1><a:dk2><a:srgbClr val=\"22242B\"/></a:dk2><a:lt2><a:srgbClr val=\"D9DBE4\"/></a:lt2><a:accent1><a:srgbClr val=\"7C83FF\"/></a:accent1><a:accent2><a:srgbClr val=\"3DD6A3\"/></a:accent2><a:accent3><a:srgbClr val=\"FFB547\"/></a:accent3><a:accent4><a:srgbClr val=\"FF6B7A\"/></a:accent4><a:accent5><a:srgbClr val=\"5CC8FF\"/></a:accent5><a:accent6><a:srgbClr val=\"C084FC\"/></a:accent6><a:hlink><a:srgbClr val=\"7C83FF\"/></a:hlink><a:folHlink><a:srgbClr val=\"A4A8B8\"/></a:folHlink></a:clrScheme><a:fontScheme name=\"VYRA\"><a:majorFont><a:latin typeface=\"Segoe UI Semibold\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont><a:minorFont><a:latin typeface=\"Segoe UI\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme><a:fmtScheme name=\"VYRA\"><a:fillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w=\"6350\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln><a:ln w=\"12700\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln><a:ln w=\"19050\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>"
}

// ---------------------------------------------------------------- RTF (oeffnet in Word, Pages, LibreOffice)
public enum RtfWriter {
    static func e(_ s: String) -> String {
        var sb = ""
        for u in s.utf16 {
            if u == 92 || u == 123 || u == 125 { sb += "\\" + String(UnicodeScalar(UInt8(u))) }
            else if u == 10 { sb += "\\line " }
            else if u > 127 { sb += "\\u\(Int16(bitPattern: u))?" }
            else { sb.unicodeScalars.append(UnicodeScalar(UInt8(u))) }
        }
        return sb
    }
    static func runs(_ text: String) -> String { MdBlocks.runs(text).map { $0.1 ? "{\\b " + e($0.0) + "}" : e($0.0) }.joined() }
    public static func build(_ title: String, _ md: String) -> String {
        var sb = "{\\rtf1\\ansi\\ansicpg1252\\deff0\\uc1{\\fonttbl{\\f0\\fswiss Segoe UI;}{\\f1\\fmodern Consolas;}}{\\colortbl;\\red40\\green44\\blue60;\\red100\\green105\\blue125;}\\viewkind4\\fs22\n"
        sb += "{\\pard\\sa240\\b\\fs40 " + e(title) + "\\par}\n"
        for b in MdBlocks.parse(md) {
            switch b.kind {
            case "h": sb += "{\\pard\\sb240\\sa120\\b\\fs\(b.level <= 2 ? 30 : 26) " + e(MdBlocks.plain(b.text)) + "\\par}\n"
            case "ul": for it in b.items { sb += "{\\pard\\fi-280\\li560\\sa60 \\bullet\\tab " + runs(it) + "\\par}\n" }
            case "ol": var n = 1; for it in b.items { sb += "{\\pard\\fi-280\\li560\\sa60 \(n).\\tab " + runs(it) + "\\par}\n"; n += 1 }
            case "code": sb += "{\\pard\\li280\\sa120\\f1\\fs19 " + e(b.text) + "\\par}\n"
            case "quote": sb += "{\\pard\\li400\\sa120\\i\\cf2 " + runs(b.text) + "\\par}\n"
            case "hr": sb += "{\\pard\\brdrb\\brdrs\\brdrw10\\sa120\\par}\n"
            case "table":
                for (ri, r) in b.rows.enumerated() {
                    let cols = max(1, r.count), w = 9000 / cols
                    sb += "\\trowd\\trgaph80"
                    for c in 0..<cols { sb += "\\clbrdrt\\brdrs\\clbrdrl\\brdrs\\clbrdrb\\brdrs\\clbrdrr\\brdrs\\cellx\(w * (c + 1))" }
                    for cell in r { sb += "\\pard\\intbl " + (ri == 0 ? "{\\b " : "{") + e(cell) + "}\\cell " }
                    sb += "\\row\n"
                }
                sb += "\\pard\\sa120\\par\n"
            default: sb += "{\\pard\\sa160 " + runs(b.text) + "\\par}\n"
            }
        }
        return sb + "}"
    }
}

// ---------------------------------------------------------------- OpenDocument-Text (.odt) fuer LibreOffice
public enum OdtWriter {
    static func x(_ s: String) -> String { HTMLEntities.xml(s) }
    static func runs(_ text: String) -> String { MdBlocks.runs(text).map { $0.1 ? "<text:span text:style-name=\"B\">" + x($0.0) + "</text:span>" : x($0.0) }.joined() }
    public static func write(_ path: String, _ title: String, _ md: String) throws {
        var body = "<text:h text:style-name=\"Title\" text:outline-level=\"1\">" + x(title) + "</text:h>"
        for b in MdBlocks.parse(md) {
            switch b.kind {
            case "h": body += "<text:h text:style-name=\"H\(min(3, max(1, b.level - 1)))\" text:outline-level=\"\(min(6, b.level))\">" + x(MdBlocks.plain(b.text)) + "</text:h>"
            case "ul", "ol":
                body += "<text:list text:style-name=\"" + (b.kind == "ul" ? "L1" : "L2") + "\">"
                for it in b.items { body += "<text:list-item><text:p text:style-name=\"P\">" + runs(it) + "</text:p></text:list-item>" }
                body += "</text:list>"
            case "code": for l in b.text.splitKeep("\n") { body += "<text:p text:style-name=\"Code\">" + x(l).rep("  ", " <text:s/>") + "</text:p>" }
            case "quote": body += "<text:p text:style-name=\"Quote\">" + runs(b.text) + "</text:p>"
            case "hr": body += "<text:p text:style-name=\"P\"/>"
            case "table":
                let cols = b.rows.map { $0.count }.max() ?? 1
                body += "<table:table table:name=\"Tabelle\"><table:table-column table:number-columns-repeated=\"\(cols)\"/>"
                for (ri, r) in b.rows.enumerated() {
                    body += "<table:table-row>"
                    for c in 0..<cols { body += "<table:table-cell table:style-name=\"Cell\" office:value-type=\"string\"><text:p text:style-name=\"" + (ri == 0 ? "TH" : "P") + "\">" + x(c < r.count ? r[c] : "") + "</text:p></table:table-cell>" }
                    body += "</table:table-row>"
                }
                body += "</table:table>"
            default: body += "<text:p text:style-name=\"P\">" + runs(b.text) + "</text:p>"
            }
        }
        let ns = "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\" xmlns:svg=\"urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0\" office:version=\"1.2\""
        let styles = "<office:automatic-styles>" +
            "<style:style style:name=\"Title\" style:family=\"paragraph\"><style:paragraph-properties fo:margin-bottom=\"0.4cm\"/><style:text-properties fo:font-size=\"22pt\" fo:font-weight=\"bold\" style:font-name=\"Segoe UI\"/></style:style>" +
            "<style:style style:name=\"H1\" style:family=\"paragraph\"><style:paragraph-properties fo:margin-top=\"0.5cm\" fo:margin-bottom=\"0.2cm\"/><style:text-properties fo:font-size=\"16pt\" fo:font-weight=\"bold\"/></style:style>" +
            "<style:style style:name=\"H2\" style:family=\"paragraph\"><style:paragraph-properties fo:margin-top=\"0.4cm\" fo:margin-bottom=\"0.15cm\"/><style:text-properties fo:font-size=\"13.5pt\" fo:font-weight=\"bold\"/></style:style>" +
            "<style:style style:name=\"H3\" style:family=\"paragraph\"><style:text-properties fo:font-size=\"12pt\" fo:font-weight=\"bold\"/></style:style>" +
            "<style:style style:name=\"P\" style:family=\"paragraph\"><style:paragraph-properties fo:margin-bottom=\"0.2cm\" fo:line-height=\"125%\"/><style:text-properties fo:font-size=\"11pt\"/></style:style>" +
            "<style:style style:name=\"TH\" style:family=\"paragraph\"><style:text-properties fo:font-size=\"10.5pt\" fo:font-weight=\"bold\"/></style:style>" +
            "<style:style style:name=\"Code\" style:family=\"paragraph\"><style:paragraph-properties fo:margin-left=\"0.5cm\"/><style:text-properties style:font-name=\"Consolas\" fo:font-family=\"Consolas\" fo:font-size=\"9.5pt\"/></style:style>" +
            "<style:style style:name=\"Quote\" style:family=\"paragraph\"><style:paragraph-properties fo:margin-left=\"0.8cm\"/><style:text-properties fo:font-style=\"italic\" fo:color=\"#555a6a\"/></style:style>" +
            "<style:style style:name=\"B\" style:family=\"text\"><style:text-properties fo:font-weight=\"bold\"/></style:style>" +
            "<style:style style:name=\"Cell\" style:family=\"table-cell\"><style:table-cell-properties fo:border=\"0.5pt solid #9aa0b0\" fo:padding=\"0.1cm\"/></style:style>" +
            "<text:list-style style:name=\"L1\"><text:list-level-style-bullet text:level=\"1\" text:bullet-char=\"•\"><style:list-level-properties text:space-before=\"0.4cm\" text:min-label-width=\"0.5cm\"/></text:list-level-style-bullet></text:list-style>" +
            "<text:list-style style:name=\"L2\"><text:list-level-style-number text:level=\"1\" style:num-format=\"1\" style:num-suffix=\".\"><style:list-level-properties text:space-before=\"0.4cm\" text:min-label-width=\"0.6cm\"/></text:list-level-style-number></text:list-style>" +
            "</office:automatic-styles>"
        let content = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-content " + ns + ">" + styles + "<office:body><office:text>" + body + "</office:text></office:body></office:document-content>"
        let zip = try ZipWriter(path)
        // "mimetype" muss als erster Eintrag unkomprimiert vorliegen.
        try zip.add("mimetype", Data("application/vnd.oasis.opendocument.text".utf8), compress: false)
        try zip.add("META-INF/manifest.xml", text: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\"><manifest:file-entry manifest:full-path=\"/\" manifest:version=\"1.2\" manifest:media-type=\"application/vnd.oasis.opendocument.text\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/><manifest:file-entry manifest:full-path=\"meta.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>")
        try zip.add("content.xml", text: content)
        try zip.add("meta.xml", text: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-meta xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:meta=\"urn:oasis:names:tc:opendocument:xmlns:meta:1.0\" office:version=\"1.2\"><office:meta><dc:title>" + x(title) + "</dc:title><meta:generator>VYRA KI</meta:generator></office:meta></office:document-meta>")
        try zip.close()
    }
}

// ---------------------------------------------------------------- Text-/Code-Dateien pruefen
public enum RawFileCheck {
    /// Liefert nil, wenn die Datei in Ordnung ist, sonst eine kurze Fehlerbeschreibung.
    public static func problem(_ ext: String, _ content: String) -> String? {
        let c = content
        if c.trimmed.isEmpty { return "Die Datei ist leer." }
        switch ext {
        case "json", "geojson":
            do { _ = try Json.parse(c); return nil } catch { return error.vyraMessage }
        case "xml", "svg", "xaml", "gpx", "kml", "rss", "atom", "opml", "plist", "csproj":
            let r = XmlCheck.check(c)
            if let e = r.error { return e }
            if ext == "svg" && r.root != "svg" { return "Das Wurzelelement muss <svg> sein." }
            return nil
        case "ics": return c.contains("BEGIN:VCALENDAR") && c.contains("END:VCALENDAR") ? (c.contains("BEGIN:VEVENT") || c.contains("BEGIN:VTODO") ? nil : "Kein Termin (BEGIN:VEVENT) enthalten.") : "BEGIN:VCALENDAR/END:VCALENDAR fehlt."
        case "vcf": return c.contains("BEGIN:VCARD") && c.contains("END:VCARD") ? nil : "BEGIN:VCARD/END:VCARD fehlt."
        case "js", "mjs": return AppChecks.jsSyntax(c, 0)
        default: return nil
        }
    }
    public static func normalize(_ ext: String, _ content: String) -> String {
        var c = content.rep("\r\n", "\n")
        if ["ics", "vcf", "bat", "cmd", "reg", "iss", "nsi"].contains(ext) { c = c.rep("\n", "\r\n") }
        if ext == "svg" && !c.trimStart().hasPrefix("<?xml") && c.contains("<svg") && !c.contains("xmlns=\"") { c = c.rep("<svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"") }
        return c
    }
    /// Kodierung wie unter Windows: .bat/.cmd in Codepage 850, .reg in UTF-16 mit BOM, PowerShell mit UTF-8-BOM, sonst UTF-8.
    public static func encode(_ ext: String, _ text: String) -> Data {
        if ext == "bat" || ext == "cmd" { return TextCodec.encodeCP850(text) }
        if ext == "reg" { return TextCodec.encodeUTF16LEWithBOM(text) }
        if ext == "ps1" || ext == "psm1" { return TextCodec.utf8(text, bom: true) }
        return TextCodec.utf8(text)
    }
}

/// XML auf Wohlgeformtheit pruefen (ersetzt XmlDocument.Load).
public enum XmlCheck {
    final class Delegate: NSObject, XMLParserDelegate {
        var root: String?
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if root == nil { root = elementName.split(separator: ":").last.map(String.init) }
        }
    }
    public static func check(_ xml: String) -> (error: String?, root: String?) {
        let p = XMLParser(data: Data(xml.utf8))
        let d = Delegate()
        p.delegate = d
        p.shouldResolveExternalEntities = false
        if !p.parse() {
            let e = p.parserError as NSError?
            return ("XML-Fehler in Zeile \(p.lineNumber), Spalte \(p.columnNumber)" + (e.map { ": " + $0.localizedDescription } ?? ""), d.root)
        }
        return (nil, d.root)
    }
}
