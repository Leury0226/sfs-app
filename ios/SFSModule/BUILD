load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Modulo SFS de SFS App (codigo propio, no viene de Telegram-iOS)
swift_library(
    name = "SFSModule",
    module_name = "SFSModule",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/Postbox:Postbox",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)
