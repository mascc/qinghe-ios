"""Swift 源码静态自检：括号配平、字符串/注释剥离、危险调用与关键符号引用。

本机没有 Swift 编译器，这份脚本只做“能不能读通”的机械检查：
1. 按 Swift 词法剥掉注释、字符串字面量与原始字符串（含插值）后配平 (), {}, []；
2. 检查 try! / fatalError / 强解包 URL(string:)! 等禁用写法；
3. 收集全部声明的顶层类型与 static func，核对本工程里以 `类型名.` 形式出现的引用。
"""

import re
import sys
from pathlib import Path

ROOT = Path(r"D:\llama_test\juku_windows_amd64.exe\guo-202610201845\QHXT\青禾学堂-1.9.4-source-ios\青禾学堂-1.9.4-source\ios\PornShopPlayer")


def strip_swift(text: str) -> str:
    """返回等长文本：注释与字符串内容替换成空格，保留换行，便于配平与行号定位。"""
    out = []
    i = 0
    n = len(text)
    depth = 0  # 处于 raw string 时 > 0 表示 # 的数量 + 1
    in_block_comment = 0
    while i < n:
        ch = text[i]
        if in_block_comment:
            if text.startswith("*/", i):
                in_block_comment -= 1
                out.append("  ")
                i += 2
                continue
            if text.startswith("/*", i):
                in_block_comment += 1
                out.append("  ")
                i += 2
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if depth:
            hashes = depth - 1
            closing = '"' + "#" * hashes
            if text.startswith(closing, i):
                out.append(" " * len(closing))
                i += len(closing)
                depth = 0
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue
        if text.startswith("/*", i):
            in_block_comment = 1
            out.append("  ")
            i += 2
            continue
        if ch == '"':
            # 原始字符串 "..."
            hashes = 0
            k = i - 1
            while k >= 0 and text[k] == "#":
                hashes += 1
                k -= 1
            if hashes:
                opening = '"' + "#" * hashes  # 已包含前导 #，跳过
                out.append(" " * (hashes + 1))
                i += 1
                depth = hashes + 1
                continue
            out.append(" ")
            i += 1
            while i < n:
                if text[i] == "\\":
                    out.append("  " if i + 1 < n else " ")
                    i += 2
                    continue
                if text[i] == '"':
                    out.append(" ")
                    i += 1
                    break
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def check_balance(path: Path, stripped: str) -> list[str]:
    problems = []
    pairs = {")": "(", "]": "[", "}": "{"}
    stack = []
    line = 1
    for ch in stripped:
        if ch == "\n":
            line += 1
        elif ch in "([{":
            stack.append((ch, line))
        elif ch in ")]}":
            if not stack:
                problems.append(f"{path.name}:{line} 多余的 {ch}")
                continue
            opening, opened_line = stack.pop()
            if opening != pairs[ch]:
                problems.append(f"{path.name}:{line} {ch} 与第 {opened_line} 行的 {opening} 不匹配")
    for opening, opened_line in stack:
        problems.append(f"{path.name}:{opened_line} 未闭合的 {opening}")
    return problems


DECLARATION = re.compile(
    r"^\s*(?:public |internal |private |fileprivate |final |@unchecked Sendable )*"
    r"(?:struct|enum|actor|class|protocol)\s+(\w+)",
    re.MULTILINE,
)


def main() -> int:
    files = sorted(ROOT.glob("*.swift"))
    if not files:
        print("没有找到 Swift 源码")
        return 1
    failures = 0
    # 已人工复核的固定常量：官网入口地址是编译期字面量，取不到 URL 属于不可能事件，
    # 这两处强解包在对齐前就是这样写的，保持原样。
    allowed: dict[tuple[str, str], int] = {("Models.swift", "URL(string:)!"): 2}
    declared: dict[str, str] = {}
    for path in files:
        raw = path.read_text(encoding="utf-8")
        stripped = strip_swift(raw)
        for problem in check_balance(path, stripped):
            print("括号问题:", problem)
            failures += 1
        for pattern, label in [
            (r"\btry!", "try!"),
            (r"\bfatalError\s*\(", "fatalError("),
            (r"URL\(string:[^\n]*\)!", "URL(string:)!"),
        ]:
            for match in re.finditer(pattern, stripped):
                line = stripped.count("\n", 0, match.start()) + 1
                key = (path.name, label)
                if allowed.get(key, 0) > 0:
                    allowed[key] -= 1
                    continue
                print(f"禁用写法 {label}: {path.name}:{line}")
                failures += 1
        for match in DECLARATION.finditer(stripped):
            declared.setdefault(match.group(1), path.name)

    # 关键符号引用：[A-Z]\w+\.  形式的类型名必须在工程里声明过（排除系统框架）
    system = {
        "URL", "URLSession", "URLRequest", "URLComponents", "URLQueryItem", "URLSessionConfiguration",
        "Data", "String", "Int", "Double", "Float", "Bool", "Date", "Set", "Array", "Dictionary",
        "Character", "CharacterSet", "NSRange", "NSRegularExpression", "NSTextCheckingResult", "NSObject",
        "NSNumber", "NSNull", "JSONSerialization", "UserDefaults", "FileManager", "Bundle", "Task",
        "MainActor", "Sendable", "Error", "LocalizedError", "AVPlayer", "AVURLAsset", "AVPlayerItem",
        "AVAsset", "AVFoundation", "UIColor", "UIImage", "UIFont", "View", "Button", "Text", "VStack",
        "HStack", "List", "Form", "NavigationView", "NavigationLink", "ToolbarItem", "Menu", "Section",
        "ForEach", "Group", "ProgressView", "Spacer", "Image", "Label", "Animation", "DispatchQueue",
        "NWListener", "NWParameters", "NWConnection", "IPv4Address", "SecKey", "SecKeyCreateWithData",
        "SecKeyCreateDecryptedData", "CCCrypt", "CCCryptorStatus", "CC_MD5", "CC_MD5_DIGEST_LENGTH",
        "CCOperation", "CCAlgorithm", "CCOptions", "kCCSuccess", "kCCDecrypt", "kCCAlgorithmAES",
        "kCCBlockSizeAES128", "CCOption", "CFData", "CFError", "CFString", "kSecAttrKeyType",
        "kSecAttrKeyTypeRSA", "kSecAttrKeyClass", "kSecAttrKeyClassPrivate", "SFSafariViewController",
        "UIViewControllerRepresentable", "UIViewController", "ObservableObject", "Published",
        "EnvironmentObject", "State", "Binding", "Color", "Font", "RoundedRectangle", "Rectangle",
        "Capsule", "Circle", "GeometryReader", "ScrollView", "TabView", "Picker", "TextField",
        "SecureField", "AsyncImage", "VideoPlayer", "Composition", "Codable", "Hashable", "Identifiable",
        "Equatable", "CaseIterable", "Encodable", "Decodable", "ExpressibleByArrayLiteral",
        "Self", "UTF8", "UTF16", "Unicode", "Locale", "TimeZone", "Calendar", "NotificationCenter",
        "IndexSet", "Range", "ClosedRange", "Substring", "Optional", "Result", "Void", "Never",
        "AnyObject", "Any", "AnyHashable", "CodingKey", "JSONDecoder", "JSONEncoder", "Combine",
        "SwiftUI", "UIKit", "AVKit", "SafariServices", "Network", "Security", "CommonCrypto",
        "Foundation", "Compression", "UIApplication", "UIScreen", "UIContentSizeCategory",
        "ViewController", "PresentationMode", "Sheet", "Toolbar", "Alert", "EditButton",
        "UInt8", "UInt16", "UInt32", "UInt64", "Int8", "Int16", "Int32", "Int64", "CGFloat",
        "CC_LONG", "StringProtocol", "Collection", "Sequence", "Decoder", "Encoder",
    }

    for path in files:
        raw = path.read_text(encoding="utf-8")
        stripped = strip_swift(raw)
        for match in re.finditer(r"\b([A-Z][A-Za-z0-9_]+)\.", stripped):
            name = match.group(1)
            if name in system or name in declared:
                continue
            line = stripped.count("\n", 0, match.start()) + 1
            print(f"疑似未声明类型引用 {name}: {path.name}:{line}")
            failures += 1

    print()
    print(f"检查文件 {len(files)} 个，声明类型 {len(declared)} 个，问题 {failures} 处")
    return 0 if failures == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
