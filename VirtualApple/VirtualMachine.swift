//
//  VirtualMachine.swift
//  VirtualApple
//
//  Created by Saagar Jha on 11/20/21.
//  Simplified by Meysam Firouzi on 2025-08-19
//

import Foundation
import Virtualization

@objc protocol _VZGDBDebugStubConfiguration {
    init(port: Int)
}

@objc protocol _VZVirtualMachineConfiguration {
    var _debugStub: _VZGDBDebugStubConfiguration { get @objc(_setDebugStub:) set }
}

@objc protocol _VZVirtualMachine {
    @available(macOS, obsoleted: 13)
    @objc(_startWithOptions:completionHandler:)
    func _start(with options: _VZVirtualMachineStartOptions) async throws
}

@objc protocol _VZVirtualMachineStartOptions {
    init()
    @available(macOS, obsoleted: 13)
    var panicAction: Bool { get set }
    @available(macOS, obsoleted: 13)
    var stopInIBootStage1: Bool { get set }
    @available(macOS, obsoleted: 13)
    var stopInIBootStage2: Bool { get set }
    @available(macOS, obsoleted: 13)
    var bootMacOSRecovery: Bool { get set }
    @available(macOS, obsoleted: 13)
    var forceDFU: Bool { get set }

    @available(macOS 13, *)
    var _panicAction: Bool { get @objc(_setPanicAction:) set }
    @available(macOS 13, *)
    var _stopInIBootStage1: Bool { get @objc(_setStopInIBootStage1:) set }
    @available(macOS 13, *)
    var _stopInIBootStage2: Bool { get @objc(_setStopInIBootStage2:) set }
    @available(macOS 13, *)
    var _forceDFU: Bool { get @objc(_setForceDFU:) set }
}

struct Configuration: Codable {
    var cpuCount: Int
    var memorySize: UInt64
    var screenWidth: Int
    var screenHeight: Int
    var screenScale: Int
    var bootIntoMacOSRecovery: Bool
    var bootIntoDFU: Bool
    var haltOnPanic: Bool
    var haltInIBoot1: Bool
    var haltInIBoot2: Bool
    var debugPort: Int?

    // Optional: folder sharing
    var sharedDirectoryPath: String?
}

struct Metadata: Codable {
    var configuration: Configuration?
    var installed = false
    var machineIdentifier: Data?
    var hardwareModel: Data?

    // Persist a stable MAC for consistent DHCP lease
    var macAddress: String?
}

@MainActor
class VirtualMachine: NSObject, VZVirtualMachineDelegate {
    var metadata: Metadata
    let url: URL
    var virtualMachine: VZVirtualMachine!
    var hardwareModel: VZMacHardwareModel!
    var machineIdentifier: VZMacMachineIdentifier!
    var installProgress: Progress!
    var running: Bool = false

    init(creatingAt url: URL) throws {
        self.url = url
        metadata = Metadata()
        super.init()
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try saveMetadata()
    }

    init(opening url: URL) throws {
        self.url = url
        metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: url.appendingPathComponent("metadata.json")))
        if metadata.installed {
            hardwareModel = VZMacHardwareModel(dataRepresentation: metadata.hardwareModel!)!
            machineIdentifier = VZMacMachineIdentifier(dataRepresentation: metadata.machineIdentifier!)!
        }
    }

    func install(ipsw: URL, diskSize: Int) async throws {
        FileManager.default.createFile(atPath: url.appendingPathComponent("disk.img").path, contents: nil)
        let handle = try FileHandle(forWritingTo: url.appendingPathComponent("disk.img"))
        try handle.truncate(atOffset: UInt64(diskSize) << 30)

        let image = try await VZMacOSRestoreImage.image(from: ipsw)
        hardwareModel = image.mostFeaturefulSupportedConfiguration!.hardwareModel
        metadata.hardwareModel = hardwareModel.dataRepresentation
        machineIdentifier = VZMacMachineIdentifier()
        metadata.machineIdentifier = machineIdentifier.dataRepresentation
        try setupVirtualMachine()
        let installer = VZMacOSInstaller(virtualMachine: virtualMachine, restoringFromImageAt: image.url)
        installProgress = installer.progress
        try await installer.install()
        metadata.installed = true
        try saveMetadata()
    }

    func setupVirtualMachine() throws {
        guard let configuration = metadata.configuration else {
            preconditionFailure("Missing configuration")
        }

        let vmConfiguration = VZVirtualMachineConfiguration()
        vmConfiguration.bootLoader = VZMacOSBootLoader()
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.auxiliaryStorage = try VZMacAuxiliaryStorage(
            creatingStorageAt: url.appendingPathComponent("aux.img"),
            hardwareModel: hardwareModel,
            options: .allowOverwrite)
        platform.machineIdentifier = machineIdentifier
        vmConfiguration.platform = platform

        vmConfiguration.cpuCount = configuration.cpuCount
        vmConfiguration.memorySize = configuration.memorySize

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: configuration.screenWidth * configuration.screenScale,
                heightInPixels: configuration.screenHeight * configuration.screenScale,
                pixelsPerInch: 100 * configuration.screenScale)
        ]
        vmConfiguration.graphicsDevices = [graphics]

        vmConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
        if #available(macOS 13, *) {
            vmConfiguration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration(),
                                               VZMacTrackpadConfiguration()]
        } else {
            vmConfiguration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }

        vmConfiguration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // === Network: Always NAT, with stable MAC ===
        let network = VZVirtioNetworkDeviceConfiguration()

        // Ensure we have a persistent, locally administered MAC
        if metadata.macAddress == nil {
            if #available(macOS 13, *) {
                metadata.macAddress = VZMACAddress.randomLocallyAdministered().string
            } else {
                func randomLAA() -> String {
                    var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
                    bytes[0] = (bytes[0] & 0b1111_1110) | 0b0000_0010
                    return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                }
                metadata.macAddress = randomLAA()
            }
            try? saveMetadata()
        }
        if let mac = try? VZMACAddress(string: metadata.macAddress!) {
            network.macAddress = mac
        }
        network.attachment = VZNATNetworkDeviceAttachment()
        vmConfiguration.networkDevices = [network]

        // === Storage ===
        let disk = try VZDiskImageStorageDeviceAttachment(
            url: url.appendingPathComponent("disk.img"), readOnly: false)
        vmConfiguration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        // === Directory Sharing (optional Virtio-FS) ===
        if let hostPath = configuration.sharedDirectoryPath, !hostPath.isEmpty {
            let hostURL = URL(fileURLWithPath: hostPath, isDirectory: true)
            let sharedDir = VZSharedDirectory(url: hostURL, readOnly: false)
            let share = VZSingleDirectoryShare(directory: sharedDir)

            let tag: String
            if #available(macOS 13, *) {
                tag = VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
            } else {
                tag = "hostshare"
            }
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: tag)
            fs.share = share
            vmConfiguration.directorySharingDevices = [fs]
        } else {
            vmConfiguration.directorySharingDevices = []
        }

        // === Optional GDB stub ===
        if let debugPort = configuration.debugPort {
            let debugStub = unsafeBitCast(NSClassFromString("_VZGDBDebugStubConfiguration")!,
                                          to: _VZGDBDebugStubConfiguration.Type.self).init(port: debugPort)
            unsafeBitCast(vmConfiguration, to: _VZVirtualMachineConfiguration.self)._debugStub = debugStub
        }

        virtualMachine = VZVirtualMachine(configuration: vmConfiguration)
        virtualMachine.delegate = self
    }

    func start() async throws {
        let configuration = metadata.configuration!

        func populateFromConfiguration(_ options: _VZVirtualMachineStartOptions) {
            if #available(macOS 13, *) {
                options._panicAction = configuration.haltOnPanic
                options._stopInIBootStage1 = configuration.haltInIBoot1
                options._stopInIBootStage2 = configuration.haltInIBoot2
                options._forceDFU = configuration.bootIntoDFU
            } else {
                options.panicAction = configuration.haltOnPanic
                options.stopInIBootStage1 = configuration.haltInIBoot1
                options.stopInIBootStage2 = configuration.haltInIBoot2
                options.forceDFU = configuration.bootIntoDFU
            }
        }

        if #available(macOS 13, *) {
            let options = VZMacOSVirtualMachineStartOptions()
            options.startUpFromMacOSRecovery = configuration.bootIntoMacOSRecovery
            populateFromConfiguration(unsafeBitCast(options, to: _VZVirtualMachineStartOptions.self))
            try await virtualMachine.start(options: options)
        } else {
            let options = unsafeBitCast(
                NSClassFromString("_VZVirtualMachineStartOptions")!,
                to: _VZVirtualMachineStartOptions.Type.self).init()
            populateFromConfiguration(options)
            options.bootMacOSRecovery = configuration.bootIntoMacOSRecovery
            try await unsafeBitCast(virtualMachine, to: _VZVirtualMachine.self)._start(with: options)
        }

        running = true
    }

    func stop() async throws {
        defer { running = false }
        try await virtualMachine.stop()
    }

    func saveMetadata() throws {
        try JSONEncoder().encode(metadata).write(to: url.appendingPathComponent("metadata.json"))
    }

    // MARK: - VZVirtualMachineDelegate

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        unsafelyRunOnMainActor { running = false }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        unsafelyRunOnMainActor { running = false }
    }
}

