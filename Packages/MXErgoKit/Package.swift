// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MXErgoKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MXErgoCore", targets: ["MXErgoCore"]),
        .library(name: "MXErgoHIDPP", targets: ["MXErgoHIDPP"]),
        .library(name: "MXErgoHID", targets: ["MXErgoHID"]),
        .library(
            name: "MXErgoPrecisionRuntimeOwner",
            targets: ["MXErgoPrecisionRuntimeOwner"]
        ),
        .executable(
            name: "MXErgoTransactionCrashHarness",
            targets: ["MXErgoTransactionCrashHarness"]
        ),
    ],
    targets: [
        .target(name: "MXErgoCore"),
        .target(name: "MXErgoHIDPP"),
        .target(
            name: "MXErgoHID",
            dependencies: ["MXErgoCore", "MXErgoHIDPP"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Pure BetterTouchTool-replacement policy for the five ordinary-HID
        // controls. It has no product, no app/helper edge, and imports no
        // CoreGraphics: it decides, and cannot cause an event to exist.
        .target(
            name: "MXErgoEventSynthesis",
            dependencies: ["MXErgoCore"]
        ),
        // Concrete CGEvent seam for the policy above. Productless: a
        // suppressing global tap is a new capability class and promotion is a
        // separate review. It holds the only CGEvent.post call site.
        .target(
            name: "MXErgoEventTap",
            dependencies: ["MXErgoEventSynthesis", "MXErgoCore"]
        ),
        // Deliberately has no product and no dependency edge from the app.
        // It is compiled only by its tests until the one-control hardware
        // trial receives a separate build-graph and byte review.
        .target(
            name: "MXErgoRestoreTrialIOHID",
            dependencies: ["MXErgoHIDPP"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Dormant production-shaped transport boundary. It deliberately has
        // no product, concrete report writer, IOKit linkage, or app/helper edge.
        .target(
            name: "MXErgoPrecisionTransport",
            dependencies: ["MXErgoHIDPP"]
        ),
        // Input-only IOHID callback owner. It has no product or dependency
        // edge from any app/helper, and contains no output-report operation.
        .target(
            name: "MXErgoPrecisionIOHIDInput",
            dependencies: [
                "MXErgoPrecisionIOHIDOwnership",
                "MXErgoPrecisionTransport",
                "MXErgoHIDPP",
            ],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Pure lifecycle for a future blocking output call. It has no product,
        // IOKit linkage, default dispatcher, or app/helper dependency edge.
        .target(
            name: "MXErgoPrecisionWriteLifecycle",
            dependencies: ["MXErgoPrecisionTransport", "MXErgoHIDPP"]
        ),
        // Concrete SetReport seam for an already-owned device. It remains
        // productless; the real-device constructor is fileprivate and its
        // narrow package factory is consumed only by the source assembly.
        .target(
            name: "MXErgoPrecisionIOHIDOutput",
            dependencies: [
                "MXErgoPrecisionWriteLifecycle",
                "MXErgoPrecisionTransport",
                "MXErgoHIDPP",
            ],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // IOKit-free ownership/admission/teardown contract. It quarantines the
        // exact endpoint bundle plus an explicit post-quiescence release anchor;
        // raw IOHID construction remains isolated in the source assembly.
        .target(
            name: "MXErgoPrecisionIOHIDOwnership",
            dependencies: [
                "MXErgoPrecisionWriteLifecycle",
                "MXErgoPrecisionTransport",
            ]
        ),
        // Sole raw-device composition point. It has no product or app/helper
        // edge and delegates all policy and teardown to the existing targets.
        .target(
            name: "MXErgoPrecisionIOHIDAssembly",
            dependencies: [
                "MXErgoPrecisionIOHIDInput",
                "MXErgoPrecisionIOHIDOutput",
                "MXErgoPrecisionIOHIDOwnership",
                "MXErgoPrecisionWriteLifecycle",
                "MXErgoPrecisionTransport",
                "MXErgoHIDPP",
            ],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Productless direct-open owner. An independent manager is used only
        // for exact enumeration; the selected device is opened directly and
        // closed by the assembly's post-quiescence release anchor.
        .target(
            name: "MXErgoPrecisionIOHIDAcquisition",
            dependencies: [
                "MXErgoPrecisionIOHIDAssembly",
                "MXErgoPrecisionIOHIDOwnership",
                "MXErgoPrecisionWriteLifecycle",
                "MXErgoPrecisionTransport",
                "MXErgoHIDPP",
            ],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Canonical schema-v3 runtime-journal bootstrap. It is productless,
        // IOKit-free, and creates or reuses one exact repository/snapshot
        // source before any device acquisition can begin.
        .target(
            name: "MXErgoPrecisionRuntimeJournal",
            dependencies: ["MXErgoHIDPP"]
        ),
        // Sole owner of the dormant precision runtime graph. It composes the
        // acquired endpoint, transport, coordinator, and temporary-diversion
        // lifecycle without exposing any component or executable edge.
        .target(
            name: "MXErgoPrecisionRuntimeComposition",
            dependencies: [
                "MXErgoPrecisionIOHIDAcquisition",
                "MXErgoPrecisionRuntimeJournal",
                "MXErgoPrecisionTransport",
                "MXErgoHIDPP",
            ]
        ),
        // Productless authorization, host-handoff, canonical-lease, bootstrap,
        // runtime-start, operation, and shutdown supervisor. It remains absent
        // from every package product and runnable target.
        .target(
            name: "MXErgoPrecisionRuntimeAdmission",
            dependencies: [
                "MXErgoPrecisionRuntimeComposition",
                "MXErgoPrecisionRuntimeJournal",
                // Read-only input diagnostics only; no transport is constructed
                // here and no packet type crosses this edge.
                "MXErgoPrecisionTransport",
                "MXErgoHIDPP",
            ]
        ),
        // Productless bridge from one captured observer run to the admission
        // handoff proof. It remains absent from every runnable target; the
        // lifecycle owner holds the restart fence around this adapter.
        .target(
            name: "MXErgoPrecisionRuntimeHostHandoff",
            dependencies: [
                "MXErgoHID",
                "MXErgoPrecisionRuntimeAdmission",
                "MXErgoHIDPP",
            ]
        ),
        // Productless executable-shaped owner. It binds one captured observer
        // run into reviewed authorization and holds a restart fence through
        // admission, runtime ownership, ordered shutdown, quit, and rollover.
        // The public Owner product is the only executable-facing surface.
        .target(
            name: "MXErgoPrecisionRuntimeLifecycle",
            dependencies: [
                "MXErgoPrecisionTransport",
                "MXErgoHID",
                "MXErgoPrecisionRuntimeAdmission",
                "MXErgoPrecisionRuntimeHostHandoff",
                "MXErgoPrecisionRuntimeComposition",
                "MXErgoHIDPP",
            ]
        ),
        // Public executable façade. Bind, confirmed admission, confirmed
        // deactivation, quit, and rollover. Control-event delivery stays out.
        .target(
            name: "MXErgoPrecisionRuntimeOwner",
            dependencies: [
                "MXErgoPrecisionTransport",
                "MXErgoCore",
                "MXErgoHID",
                "MXErgoHIDPP",
                "MXErgoPrecisionRuntimeLifecycle",
                "MXErgoPrecisionRuntimeAdmission",
                "MXErgoPrecisionRuntimeHostHandoff",
                // Journal rotation only. The canonical journal source stays the
                // single authority; the owner must not grow a second reader.
                "MXErgoPrecisionRuntimeJournal",
            ]
        ),
        .executableTarget(
            name: "MXErgoTransactionCrashHarness",
            dependencies: ["MXErgoHIDPP"],
            path: "Tools/MXErgoTransactionCrashHarness"
        ),
        .testTarget(name: "MXErgoCoreTests", dependencies: ["MXErgoCore"]),
        .testTarget(name: "MXErgoHIDPPTests", dependencies: ["MXErgoHIDPP"]),
        .testTarget(
            name: "MXErgoHIDTests",
            dependencies: ["MXErgoHID", "MXErgoCore", "MXErgoHIDPP"]
        ),
        .testTarget(
            name: "MXErgoEventSynthesisTests",
            dependencies: ["MXErgoEventSynthesis", "MXErgoCore"]
        ),
        .testTarget(
            name: "MXErgoEventTapTests",
            dependencies: [
                "MXErgoEventTap",
                "MXErgoEventSynthesis",
                "MXErgoCore",
            ]
        ),
        .testTarget(
            name: "MXErgoRestoreTrialIOHIDTests",
            dependencies: ["MXErgoRestoreTrialIOHID", "MXErgoHIDPP"]
        ),
        // Direct tests for the pure dormant transport policy.
        .testTarget(
            name: "MXErgoPrecisionTransportTests",
            dependencies: ["MXErgoPrecisionTransport", "MXErgoHIDPP"]
        ),
        .testTarget(
            name: "MXErgoPrecisionIOHIDInputTests",
            dependencies: [
                "MXErgoPrecisionIOHIDInput",
                "MXErgoPrecisionTransport",
                "MXErgoHIDPP",
            ]
        ),
        .testTarget(
            name: "MXErgoPrecisionWriteLifecycleTests",
            dependencies: [
                "MXErgoPrecisionWriteLifecycle",
                "MXErgoPrecisionTransport",
                "MXErgoHIDPP",
            ]
        ),
        .testTarget(
            name: "MXErgoPrecisionIOHIDOutputTests",
            dependencies: [
                "MXErgoPrecisionIOHIDOutput",
                "MXErgoPrecisionWriteLifecycle",
                "MXErgoPrecisionTransport",
                "MXErgoHIDPP",
            ]
        ),
        .testTarget(
            name: "MXErgoPrecisionIOHIDOwnershipTests",
            dependencies: [
                "MXErgoPrecisionIOHIDOwnership",
                "MXErgoPrecisionWriteLifecycle",
                "MXErgoPrecisionTransport",
                "MXErgoHIDPP",
            ]
        ),
        // Fake-runtime tests for the productless source assembly. Neither this
        // test target nor the assembly is exposed through a package product.
        .testTarget(
            name: "MXErgoPrecisionIOHIDAssemblyTests",
            dependencies: [
                "MXErgoPrecisionIOHIDAssembly",
                "MXErgoPrecisionIOHIDOwnership",
                "MXErgoPrecisionWriteLifecycle",
                "MXErgoPrecisionTransport",
                "MXErgoHIDPP",
            ]
        ),
        .testTarget(
            name: "MXErgoPrecisionIOHIDAcquisitionTests",
            dependencies: [
                "MXErgoPrecisionIOHIDAcquisition",
                "MXErgoPrecisionIOHIDOwnership",
                "MXErgoPrecisionWriteLifecycle",
                "MXErgoPrecisionTransport",
                "MXErgoHIDPP",
            ]
        ),
        .testTarget(
            name: "MXErgoPrecisionRuntimeCompositionTests",
            dependencies: [
                "MXErgoPrecisionRuntimeComposition",
                "MXErgoPrecisionIOHIDAcquisition",
                "MXErgoPrecisionRuntimeJournal",
                "MXErgoPrecisionWriteLifecycle",
                "MXErgoPrecisionTransport",
                "MXErgoHIDPP",
            ]
        ),
        .testTarget(
            name: "MXErgoPrecisionRuntimeJournalTests",
            dependencies: [
                "MXErgoPrecisionRuntimeJournal",
                "MXErgoHIDPP",
            ]
        ),
        .testTarget(
            name: "MXErgoPrecisionRuntimeAdmissionTests",
            dependencies: [
                "MXErgoPrecisionRuntimeAdmission",
                "MXErgoPrecisionRuntimeComposition",
                "MXErgoPrecisionRuntimeJournal",
                "MXErgoHIDPP",
            ]
        ),
        .testTarget(
            name: "MXErgoPrecisionRuntimeHostHandoffTests",
            dependencies: [
                "MXErgoPrecisionRuntimeHostHandoff",
                "MXErgoPrecisionRuntimeAdmission",
                "MXErgoHID",
                "MXErgoHIDPP",
            ]
        ),
        .testTarget(
            name: "MXErgoPrecisionRuntimeLifecycleTests",
            dependencies: [
                "MXErgoPrecisionRuntimeLifecycle",
                "MXErgoPrecisionRuntimeAdmission",
                "MXErgoPrecisionRuntimeHostHandoff",
                "MXErgoPrecisionRuntimeComposition",
                "MXErgoHID",
                "MXErgoHIDPP",
            ]
        ),
        .testTarget(
            name: "MXErgoPrecisionRuntimeOwnerTests",
            dependencies: [
                "MXErgoPrecisionRuntimeOwner",
                "MXErgoPrecisionRuntimeLifecycle",
                "MXErgoPrecisionRuntimeAdmission",
                "MXErgoPrecisionRuntimeHostHandoff",
                "MXErgoPrecisionRuntimeComposition",
                "MXErgoCore",
                "MXErgoHID",
                "MXErgoHIDPP",
            ]
        ),
    ]
)
