//
//  DylibTestManager.swift
//  TrollFools
//
//  Created for Dylib Dynamic Testing inside Self-Process.
//

import CocoaLumberjackSwift
import Foundation
import MachOKit

/// ข้อผิดพลาดที่อาจเกิดขึ้นระหว่างการทดสอบ Dylib
enum DylibTestError: LocalizedError {
    case dylibNotFound(String)
    case executableNotFound(String)
    case signingFailed(String)
    case ctBypassFailed(String)
    case loadFailed(String)
    case unloadFailed(String)
    case dylibNotLoaded

    var errorDescription: String? {
        switch self {
        case let .dylibNotFound(path):
            return "ไม่พบไฟล์ dylib ที่ตำแหน่ง: \(path)"
        case let .executableNotFound(name):
            return "ไม่พบไฟล์ Helper Executable: \(name)"
        case let .signingFailed(reason):
            return "การเซ็นสัญญาด้วย ldid ล้มเหลว: \(reason)"
        case let .ctBypassFailed(reason):
            return "การทำ CoreTrust Bypass (ct_bypass) ล้มเหลว: \(reason)"
        case let .loadFailed(reason):
            return "dlopen ล้มเหลว: \(reason)"
        case let .unloadFailed(reason):
            return "dlclose ล้มเหลว: \(reason)"
        case .dylibNotLoaded:
            return "dylib ตัวนี้ยังไม่ได้ถูกโหลดเข้า Memory"
        }
    }
}

final class DylibTestManager {
    static let shared = DylibTestManager()

    /// เก็บ pointer handle ของ dylib แต่ละตัวที่ถูกโหลดอยู่ [Path: Handle]
    private(set) var loadedHandles: [URL: UnsafeMutableRawPointer] = [:]

    private init() {}

    // MARK: - Sign & Load Workflow

    /// ทดสอบ Sign, Bypass CoreTrust และโหลด dylib เข้า Process ตัวเองผ่าน dlopen
    @discardableResult
    func prepareAndLoadDylib(
        at dylibURL: URL,
        forceSign: Bool = true,
        teamID: String? = nil
    ) throws -> UnsafeMutableRawPointer {
        DDLogInfo("[DylibTestManager] 🚀 เริ่มกระบวนการเตรียมและโหลด dylib: \(dylibURL.lastPathComponent)")

        guard FileManager.default.fileExists(atPath: dylibURL.path) else {
            DDLogError("[DylibTestManager] ❌ ไม่พบไฟล์ที่ Path: \(dylibURL.path)")
            throw DylibTestError.dylibNotFound(dylibURL.path)
        }

        // 0. 🔥 คัดลอกไฟล์ไปยังโฟลเดอร์ tmp ของตัวแอป
        let tmpDirectory = FileManager.default.temporaryDirectory
        let workingDylibURL = tmpDirectory.appendingPathComponent(dylibURL.lastPathComponent)

        if FileManager.default.fileExists(atPath: workingDylibURL.path) {
            try? FileManager.default.removeItem(at: workingDylibURL)
        }
        try FileManager.default.copyItem(at: dylibURL, to: workingDylibURL)
        chmod(workingDylibURL.path, 0o777)

        // 1. ทำการ Pseudo-Sign ไฟล์ dylib ด้วย ldid
        try pseudoSignDylib(workingDylibURL, force: forceSign)

        // 2. 🔥 ขั้นตอนสำคัญ: ทำ CoreTrust Bypass (ct_bypass) เพื่อให้ Kernel ยอมรับ dlopen
        let targetTeamID = teamID ?? getAppTeamID()
        try applyCoreTrustBypass(workingDylibURL, teamID: targetTeamID)

        // 3. ปรับสิทธิ์ Owner ของไฟล์ (chown 33:33 / mobile:mobile) ป้องกัน permission denied
        try? changeOwnerToMobile(workingDylibURL)

        // 4. เรียก dlopen เพื่อ Map dylib เข้า Memory ของแอป
        return try loadDylib(at: workingDylibURL)
    }

    // MARK: - Core dlopen & dlclose

    /// เรียก dlopen เพื่อโหลด dylib เข้าแอปตัวเอง
    func loadDylib(at dylibURL: URL) throws -> UnsafeMutableRawPointer {
        let path = dylibURL.path

        // หากเคยโหลดไว้แล้ว ให้คืนค่า handle เดิม
        if let existingHandle = loadedHandles[dylibURL] {
            DDLogInfo("[DylibTestManager] ℹ️ พบ Handle เดิมอยู่ใน Memory แล้ว: \(path)")
            return existingHandle
        }

        DDLogInfo("[DylibTestManager] ⏳ กำลังสั่ง dlopen(\(path), RTLD_NOW)...")

        // เคลียร์ error buffer เก่าก่อน
        dlerror()

        // เรียกใช้ dlopen (RTLD_NOW: resolve symbols ทั้งหมดทันที)
        guard let handle = dlopen(path, RTLD_NOW) else {
            var errorMsg = "Unknown error"
            if let errorPointer = dlerror() {
                errorMsg = String(cString: errorPointer)
            }
            DDLogError("[DylibTestManager] ❌ dlopen ล้มเหลว! ข้อความตอบกลับจาก dyld:\n\(errorMsg)")
            throw DylibTestError.loadFailed(errorMsg)
        }

        loadedHandles[dylibURL] = handle
        DDLogInfo("[DylibTestManager] ✅ โหลด dylib สำเร็จ! Pointer: \(handle)")
        return handle
    }

    /// เรียก dlclose เพื่อปลด dylib ออกจาก Memory
    func unloadDylib(at dylibURL: URL) throws {
        guard let handle = loadedHandles[dylibURL] else {
            throw DylibTestError.dylibNotLoaded
        }

        DDLogInfo("[DylibTestManager] ⏳ กำลังปลด dylib ออกจาก Memory (dlclose)...")
        let result = dlclose(handle)
        if result == 0 {
            loadedHandles.removeValue(forKey: dylibURL)
            DDLogInfo("[DylibTestManager] ✅ Unload dylib สำเร็จ: \(dylibURL.lastPathComponent)")
        } else {
            var errorMsg = "Unknown error"
            if let errorPointer = dlerror() {
                errorMsg = String(cString: errorPointer)
            }
            DDLogError("[DylibTestManager] ❌ dlclose ล้มเหลว: \(errorMsg)")
            throw DylibTestError.unloadFailed(errorMsg)
        }
    }

    /// ตรวจสอบว่า dylib ณ Path นี้ถูกโหลดอยู่หรือไม่
    func isLoaded(dylibURL: URL) -> Bool {
        return loadedHandles[dylibURL] != nil
    }

    // MARK: - TrollFools Core Signing & Bypass Helpers

    /// ใช้ ldid เพื่อลงนาม Ad-hoc ให้ dylib
    private func pseudoSignDylib(_ target: URL, force: Bool = false) throws {
        let ldidExecutableURL = try findExecutable("ldid")

        var hasCodeSign = false

        // ตรวจสอบโครงสร้าง Mach-O ว่ามี Code Signature แล้วหรือยังผ่าน MachOKit
        if let targetFile = try? MachOKit.loadFromFile(url: target) {
            switch targetFile {
            case let .machO(machOFile):
                for command in machOFile.loadCommands {
                    if case .codeSignature = command {
                        hasCodeSign = true
                        break
                    }
                }
            case let .fat(fatFile):
                if let machOFiles = try? fatFile.machOFiles() {
                    for machOFile in machOFiles {
                        for command in machOFile.loadCommands {
                            if case .codeSignature = command {
                                hasCodeSign = true
                                break
                            }
                        }
                    }
                }
            }
        }

        if hasCodeSign && !force {
            DDLogInfo("[DylibTestManager] ℹ️ dylib มี Code Signature อยู่แล้ว ข้ามขั้นตอน ldid")
            return
        }

        DDLogInfo("[DylibTestManager] ⚡️ Executing: ldid -S \(target.lastPathComponent)")

        // 🔥 กำหนด Root Persona (UID: 0, GID: 0) เพื่อยกระดับสิทธิ์ Root ในการเซ็นไฟล์
        let rootPersona = AuxiliaryExecute.PersonaOptions(uid: 0, gid: 0)

        let receipt = AuxiliaryExecute.spawn(
            command: ldidExecutableURL.path,
            args: ["-S", target.path],
            personaOptions: rootPersona
        )

        let stdout = receipt.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = receipt.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if !stdout.isEmpty { DDLogInfo("[ldid stdout] \(stdout)") }
        if !stderr.isEmpty { DDLogError("[ldid stderr] \(stderr)") }

        guard case let .exit(code) = receipt.terminationReason, code == EXIT_SUCCESS else {
            DDLogError("[DylibTestManager] ❌ ldid ทำงานไม่สำเร็จ Exit Code: \(receipt.terminationReason)")
            throw DylibTestError.signingFailed("Code \(receipt.terminationReason)")
        }

        DDLogInfo("[DylibTestManager] ✅ ldid pseudo-sign สำเร็จ: \(target.lastPathComponent)")
    }

    /// ใช้ ct_bypass เพื่อทำ CoreTrust Bypass ด้วย Root privilege
    private func applyCoreTrustBypass(_ target: URL, teamID: String) throws {
        let ctBypassURL = try findExecutable("ct_bypass")

        DDLogInfo("[DylibTestManager] ⚡️ Executing: ct_bypass -r -i \(target.lastPathComponent) -t \(teamID)")

        // 🔥 กำหนด Root Persona (UID: 0, GID: 0)
        let rootPersona = AuxiliaryExecute.PersonaOptions(uid: 0, gid: 0)

        let receipt = AuxiliaryExecute.spawn(
            command: ctBypassURL.path,
            args: ["-r", "-i", target.path, "-t", teamID],
            personaOptions: rootPersona
        )

        let stdout = receipt.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = receipt.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if !stdout.isEmpty { DDLogInfo("[ct_bypass stdout] \(stdout)") }
        if !stderr.isEmpty { DDLogError("[ct_bypass stderr] \(stderr)") }

        guard case let .exit(code) = receipt.terminationReason, code == EXIT_SUCCESS else {
            DDLogError("[DylibTestManager] ❌ ct_bypass ทำงานไม่สำเร็จ Exit Code: \(receipt.terminationReason)")
            throw DylibTestError.ctBypassFailed("Code \(receipt.terminationReason)")
        }

        DDLogInfo("[DylibTestManager] ✅ ct_bypass สำเร็จสำหรับ TeamID (\(teamID)): \(target.lastPathComponent)")
    }

    /// เปลี่ยน Owner ของไฟล์ dylib ให้เป็น mobile/installd (UID 33)
    private func changeOwnerToMobile(_ target: URL) throws {
        guard let chownURL = try? findExecutable("chown") else { return }
        DDLogInfo("[DylibTestManager] ⚡️ Changing file owner to 33:33 (mobile)...")

        let rootPersona = AuxiliaryExecute.PersonaOptions(uid: 0, gid: 0)
        _ = AuxiliaryExecute.spawn(
            command: chownURL.path,
            args: ["33:33", target.path],
            personaOptions: rootPersona
        )
    }

    // MARK: - Utility Helpers

    /// ค้นหา Helper Binary ต่างๆ (ldid, ct_bypass, chown)
    private func findExecutable(_ name: String) throws -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: nil) {
            return url
        }
        if let firstArg = ProcessInfo.processInfo.arguments.first {
            let execURL = URL(fileURLWithPath: firstArg)
                .deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: execURL.path) {
                return execURL
            }
        }
        if let tfProxy = LSApplicationProxy(forIdentifier: Constants.gAppIdentifier),
           let tfBundleURL = tfProxy.bundleURL()
        {
            let execURL = tfBundleURL.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: execURL.path) {
                return execURL
            }
        }
        DDLogError("[DylibTestManager] ❌ ไม่พบ Helper Binary: \(name)")
        throw DylibTestError.executableNotFound(name)
    }

    /// ดึง Team ID ของตัวแอปปัจจุบัน
    /*private func getAppTeamID() -> String {
        if let teamID = Bundle.main.infoDictionary?["AppIdentifierPrefix"] as? String {
            return teamID.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        return "0000000000" // Default fallback Team ID สำหรับ TrollStore
    }
}*/

        /// ดึง Team ID ของตัวแอปปัจจุบัน
    private func getAppTeamID() -> String {
        return "GXZ23M5TP2"
    }
}
