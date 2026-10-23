// swift-tools-version:5.9
// VYRAKit: der plattformunabhaengige KI-Kern der VYRA-KI-iPhone-App (portiert aus VYRA 4.15.1, VYRA.GXCore.cs)
// und die lokale Modellanbindung an llama.cpp (dieselbe Version b7380 wie unter Windows).
//
// iOS/macOS: llama kommt als offizielles, unveraendertes llama.xcframework aus dem GitHub-Release b7380
//            (Pruefsumme unten fest hinterlegt; Metal-Beschleunigung ist eingebaut).
// Linux:     nur fuer die automatischen Tests; llama.cpp b7380 wird lokal gebaut (scripts/linux-test-setup.sh).
import PackageDescription

#if os(Linux)
let llamaTarget: Target = .systemLibrary(name: "llama", path: "Sources/llama-system")
#else
let llamaTarget: Target = .binaryTarget(
    name: "llama",
    url: "https://github.com/ggml-org/llama.cpp/releases/download/b7380/llama-b7380-xcframework.zip",
    checksum: "ec03c93110241d722d5a4c8937196090943346c98e248b204f35afec3c7fe1f8")
#endif

let package = Package(
    name: "VYRAKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VYRAKit", targets: ["VYRACore", "VYRALlama"])
    ],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        llamaTarget,
        .target(name: "VYRACore", dependencies: ["CZlib"], path: "Sources/VYRACore",
                resources: [.copy("Resources")]),
        .target(name: "VYRALlama", dependencies: ["VYRACore", "llama"], path: "Sources/VYRALlama"),
        .testTarget(name: "VYRACoreTests", dependencies: ["VYRACore", "VYRALlama"], path: "Tests/VYRACoreTests")
    ],
    swiftLanguageVersions: [.v5]
)
