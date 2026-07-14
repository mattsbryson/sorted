import Foundation

// stdin: JSON array of strings. stdout: JSON array of [Double], one
// TitleEmbedding vector per input string, in order. Exits 1 on bad input.
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let texts = try? JSONDecoder().decode([String].self, from: input) else {
    FileHandle.standardError.write(Data("embedtool: expected a JSON array of strings on stdin\n".utf8))
    exit(1)
}
let vectors = texts.map { TitleEmbedding.vector(for: $0) }
let output = try JSONEncoder().encode(vectors)
FileHandle.standardOutput.write(output)
