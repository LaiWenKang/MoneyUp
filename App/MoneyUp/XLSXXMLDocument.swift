import Foundation
import MoneyUpCore

final class XLSXXMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XLSXXMLNode] = []
    init(_ name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
    func child(_ name: String) -> XLSXXMLNode? { children.first { $0.name == name } }
    var content: String {
        let nodes = ["si", "is"].contains(name) ? children.filter { ["t", "r"].contains($0.name) } : children
        return text + nodes.map(\.content).joined()
    }
}

final class XLSXXMLDocument: NSObject, XMLParserDelegate {
    private var stack: [XLSXXMLNode] = []
    private var root: XLSXXMLNode?
    private var nodes = 0
    private var failure: Error?

    static func parse(_ data: Data) throws -> XLSXXMLNode {
        let delegate = XLSXXMLDocument()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root, delegate.failure == nil else {
            throw delegate.failure ?? CSVImportViewError.unsupportedDocument
        }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        nodes += 1
        guard !Task.isCancelled, nodes <= 500_000, stack.count < 32, attributeDict.count <= 64 else {
            failure = CSVImportViewError.documentTooLarge; parser.abortParsing(); return
        }
        let name = String(elementName.split(separator: ":").last ?? Substring(elementName))
        let node = XLSXXMLNode(name, attributes: attributeDict)
        if let parent = stack.last { parent.children.append(node) }
        else if root == nil { root = node }
        else { failure = CSVImportViewError.unsupportedDocument; parser.abortParsing(); return }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let node = stack.last, ["t", "v", "f"].contains(node.name) else { return }
        node.text += string
        if node.text.utf8.count > TransactionCSVImporter.maximumFieldByteCount {
            failure = CSVImportViewError.documentTooLarge; parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        failure = CSVImportViewError.unsupportedDocument; parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        failure = CSVImportViewError.unsupportedDocument; parser.abortParsing()
    }
}
