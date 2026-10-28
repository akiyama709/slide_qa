// swift-tools-version: 6.2
import PackageDescription

let package=Package(
    name:"SlideQAPrototype",
    defaultLocalization:"en",
    platforms:[.macOS("26.0")],
    products:[
        .executable(name:"SlideQAPrototype",targets:["RealDeckEvidenceApp"]),
        .executable(name:"SlideQADemoCheck",targets:["DemoDeckCheck"])
    ],
    targets:[
        .target(name:"SlideQACore",resources:[.process("Resources")]),
        .target(name:"RealDeckEvidenceCore",dependencies:["SlideQACore"]),
        .target(name:"NativeLocalIO",dependencies:["RealDeckEvidenceCore","SlideQACore"]),
        .executableTarget(name:"RealDeckEvidenceApp",dependencies:["RealDeckEvidenceCore","SlideQACore","NativeLocalIO"]),
        .executableTarget(name:"DemoDeckCheck",dependencies:["RealDeckEvidenceCore","SlideQACore"]),
        .testTarget(name:"RealDeckEvidenceTests",dependencies:["RealDeckEvidenceCore","SlideQACore","NativeLocalIO"])
    ],swiftLanguageModes:[.v6]
)
