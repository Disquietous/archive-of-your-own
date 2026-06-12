import Foundation
import CommonCrypto

enum RecoveryKey {

    static func generate() -> String {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        var groups: [String] = []
        for _ in 0..<6 {
            var group = ""
            for _ in 0..<4 {
                let idx = Int.random(in: 0..<chars.count)
                group.append(chars[chars.index(chars.startIndex, offsetBy: idx)])
            }
            groups.append(group)
        }
        return groups.joined(separator: "-")
    }

    static func encryptPassword(_ password: String, withRecoveryKey key: String) -> Data? {
        guard let passwordData = password.data(using: .utf8) else { return nil }
        let aesKey = deriveKey(from: key)

        var iv = Data(count: kCCBlockSizeAES128)
        _ = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, kCCBlockSizeAES128, $0.baseAddress!) }

        let bufferSize = passwordData.count + kCCBlockSizeAES128
        var cipherData = Data(count: bufferSize)
        var numBytesEncrypted: size_t = 0

        let status = cipherData.withUnsafeMutableBytes { cipherPtr in
            passwordData.withUnsafeBytes { dataPtr in
                aesKey.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, kCCKeySizeAES256,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, passwordData.count,
                            cipherPtr.baseAddress, bufferSize,
                            &numBytesEncrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        cipherData.count = numBytesEncrypted
        return iv + cipherData
    }

    static func decryptPassword(fromBlob blob: Data, withRecoveryKey key: String) -> String? {
        guard blob.count > kCCBlockSizeAES128 else { return nil }
        let iv = blob.prefix(kCCBlockSizeAES128)
        let cipherData = blob.dropFirst(kCCBlockSizeAES128)
        let aesKey = deriveKey(from: key)

        let bufferSize = cipherData.count + kCCBlockSizeAES128
        var plainData = Data(count: bufferSize)
        var numBytesDecrypted: size_t = 0

        let status = plainData.withUnsafeMutableBytes { plainPtr in
            cipherData.withUnsafeBytes { cipherPtr in
                aesKey.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, kCCKeySizeAES256,
                            ivPtr.baseAddress,
                            cipherPtr.baseAddress, cipherData.count,
                            plainPtr.baseAddress, bufferSize,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        plainData.count = numBytesDecrypted
        return String(data: plainData, encoding: .utf8)
    }

    // MARK: - Storage

    private static let blobKey = "recoveryEncryptedBlob"

    static func storeEncryptedBlob(_ blob: Data) {
        UserDefaults.standard.set(blob, forKey: blobKey)
    }

    static func loadEncryptedBlob() -> Data? {
        UserDefaults.standard.data(forKey: blobKey)
    }

    static func deleteEncryptedBlob() {
        UserDefaults.standard.removeObject(forKey: blobKey)
    }

    static var hasRecoveryKey: Bool {
        loadEncryptedBlob() != nil
    }

    // MARK: - Key Derivation

    private static func deriveKey(from recoveryKey: String) -> Data {
        let password = recoveryKey.replacingOccurrences(of: "-", with: "")
        let salt = "ao3-archive-reader-salt".data(using: .utf8)!
        var derivedKey = Data(count: kCCKeySizeAES256)
        _ = derivedKey.withUnsafeMutableBytes { derivedPtr in
            password.withCString { passPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr, password.utf8.count,
                        saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        200_000,
                        derivedPtr.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES256
                    )
                }
            }
        }
        return derivedKey
    }

    // MARK: - Failure Tracking

    private static let failureCountKey = "unlockFailureCount"
    private static let wipeThresholdKey = "wipeOnFailureCount"

    static var failureCount: Int {
        get { UserDefaults.standard.integer(forKey: failureCountKey) }
        set { UserDefaults.standard.set(newValue, forKey: failureCountKey) }
    }

    static var wipeThreshold: Int {
        get { UserDefaults.standard.integer(forKey: wipeThresholdKey) }
        set { UserDefaults.standard.set(newValue, forKey: wipeThresholdKey) }
    }

    static func recordFailure() {
        failureCount += 1
    }

    static func resetFailureCount() {
        failureCount = 0
    }

    static func shouldWipe() -> Bool {
        let threshold = wipeThreshold
        return threshold > 0 && failureCount >= threshold
    }

    static func wipeDatabase() {
        let dbPath = RustBridge.databasePath()
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: dbPath + "-wal")
        try? FileManager.default.removeItem(atPath: dbPath + "-shm")
        deleteEncryptedBlob()
        failureCount = 0
        UserDefaults.standard.set(false, forKey: "userSetDbPassword")
    }
}
