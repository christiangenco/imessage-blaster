import Foundation
import AppKit

// Custom error stream for Swift (equivalent to fputs(..., stderr))
struct StderrOutputStream: TextOutputStream {
    func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}
var standardError = StderrOutputStream()

// Helper to read all data from stdin
func readStdinToEnd() -> Data {
    var data = Data()
    let stdin = FileHandle.standardInput
    while true {
        let chunk = stdin.readData(ofLength: 4096)
        if chunk.isEmpty {
            break
        }
        data.append(chunk)
    }
    return data
}

let inputData = readStdinToEnd()

if inputData.isEmpty {
    print("SwiftParserError: No data received on stdin.", to: &standardError)
    exit(1)
}

// Try typedstream unarchiving first
if let unarchiver = NSUnarchiver(forReadingWith: inputData) {
    do {
        if let attributedString = unarchiver.decodeObject() as? NSAttributedString {
            print(attributedString.string)
            exit(0)
        }
    } catch {
        print("SwiftParserError: Typedstream decoding failed: \(error.localizedDescription)", to: &standardError)
    }
} else {
    print("SwiftParserError: Failed to create typedstream unarchiver", to: &standardError)
}

// Define the set of allowed classes for secure unarchiving
let allowedClasses: [AnyClass] = [
    NSAttributedString.self, NSMutableAttributedString.self,
    NSString.self, NSMutableString.self,
    NSDictionary.self, NSMutableDictionary.self,
    NSArray.self, NSMutableArray.self,
    NSNumber.self,
    NSValue.self,
    NSData.self, NSMutableData.self,
    NSURL.self,
    NSObject.self,
    // Add AppKit classes
    NSColor.self,
    NSFont.self,
    NSParagraphStyle.self,
    NSMutableParagraphStyle.self,
    NSTextAttachment.self
]

// Try modern unarchiving
do {
    let unarchiver = try NSKeyedUnarchiver(forReadingFrom: inputData)
    unarchiver.requiresSecureCoding = false

    if let attributedString = try unarchiver.decodeObject(of: NSAttributedString.self, forKey: NSKeyedArchiveRootObjectKey) {
        print(attributedString.string)
        exit(0)
    }
} catch {
    // Continue to next approach if this fails
    print("SwiftParserError: Modern unarchiving failed: \(error.localizedDescription)", to: &standardError)
}

// Try creating a string directly from the data
if let string = String(data: inputData, encoding: .utf8) {
    // Look for text content between quotes or after certain markers
    let patterns = [
        #"\+([^"]+)"#,  // Text after + symbol
        #"\"([^\"]+)\""#, // Text between quotes
        #"([a-zA-Z0-9\s.,!?-]+)"# // Basic text pattern
    ]

    for pattern in patterns {
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(string.startIndex..., in: string)
            if let match = regex.firstMatch(in: string, options: [], range: range) {
                let matchRange = Range(match.range(at: 1), in: string)!
                let extractedText = String(string[matchRange])
                if !extractedText.isEmpty {
                    print(extractedText)
                    exit(0)
                }
            }
        }
    }
}

// If all attempts fail, try one last approach with a custom decoder
do {
    let unarchiver = try NSKeyedUnarchiver(forReadingFrom: inputData)
    unarchiver.requiresSecureCoding = false

    if let root = try unarchiver.decodeTopLevelObject() {
        if let attributedString = root as? NSAttributedString {
            print(attributedString.string)
            exit(0)
        } else if let dict = root as? NSDictionary {
            // Try to find string content in the dictionary
            if let text = dict["NS.string"] as? String {
                print(text)
                exit(0)
            }
        }
    }
} catch {
    print("SwiftParserError: Custom decoding failed: \(error.localizedDescription)", to: &standardError)
}

// If all attempts fail, print detailed error information
print("SwiftParserError: Failed to extract text from data.", to: &standardError)
print("Data length: \(inputData.count) bytes", to: &standardError)
print("First 100 bytes: \(inputData.prefix(100).map { String(format: "%02x", $0) }.joined())", to: &standardError)
exit(1)
