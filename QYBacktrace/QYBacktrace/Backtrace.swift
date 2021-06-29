//
//  QYBacktrace.swift
//  QYBacktrace
//
//  Created by Joey on 2021/6/29.
//

import Foundation

@_silgen_name("mach_backtrace")
public func backtrace(
    _ thread: thread_t,
    stack: UnsafeMutablePointer<UnsafeMutableRawPointer?>!,
    _ maxSymbols: Int32
) -> Int32

@_silgen_name("backtrace_symbols")
fileprivate func backtrace_symbols(
    _ stack: UnsafePointer<UnsafeMutableRawPointer?>!,
    _ frame: Int32
) -> UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>!

@_silgen_name("swift_demangle")
public
func stdlib_demangleImpl(
    mangledName: UnsafePointer<CChar>?,
    mangledNameLength: UInt,
    outputBuffer: UnsafeMutablePointer<CChar>?,
    outputBufferSize: UnsafeMutablePointer<UInt>?,
    flags: UInt32
) -> UnsafeMutablePointer<CChar>?

@objc public class Backtrace: NSObject {
        
    private static var main_thread_t: mach_port_t?
    
    public static var useSystem = false
    
    public static var useSwiftDemangle = true
    
    public static func setup(system: Bool = false, swiftDemangle: Bool = true) {
        useSystem = system
        useSwiftDemangle = swiftDemangle
        DispatchQueue.main.async {
            main_thread_t = mach_thread_self()
        }
    }
    
    public static func backtrace(_ thread: Thread) -> String {
        if thread == Thread.current && useSystem {
            return Thread.callStackSymbols.joined(separator: "\n")
        }
        let mach = machThread(from: thread)
        return backtrace(t: mach)
    }
    
    public static func backtraceMainThread() -> String {
        return backtrace(.main)
    }
    
    public static func backtraceCurrentThread() -> String {
        return backtrace(.current)
    }
    
    public static func backtraceAllThread() -> String {
        var count: mach_msg_type_number_t = 0
        var threads: thread_act_array_t!
        guard task_threads(mach_task_self_, &(threads), &count) == KERN_SUCCESS else {
            let result = [backtrace(t: mach_thread_self())]
            var symbols = [String]()
            for (i, symbol) in result.enumerated() {
                let prefix = "Thread \(i): \n"
                symbols.append(prefix + symbol)
            }
            return symbols.joined(separator: "\n\n")
        }
        var symbols = [String]()
        for i in 0..<count {
            let prefix = "Thread \(i): \n"
            symbols.append(prefix + backtrace(t: threads[Int(i)]))
        }
        return symbols.joined(separator: "\n\n")
    }
    
    fileprivate static func backtrace(t: thread_t) -> String {
        let maxSize: Int32 = 128
        let addrs = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(maxSize))
        defer { addrs.deallocate() }
        let frameCount = QYBacktrace.backtrace(t, stack: addrs, maxSize)
        var symbols: [String] = []
        
        if useSwiftDemangle {
            let buf = UnsafeBufferPointer(start: addrs, count: Int(frameCount))
            for (index, addr) in buf.enumerated() {
                guard let addr = addr else { continue }
                let addrValue = UInt(bitPattern: addr)
                let symbol = getSymbol(address: addrValue, index: index)
                symbols.append(symbol)
            }
        } else {
            if let bs = backtrace_symbols(addrs, frameCount) {
                symbols = UnsafeBufferPointer(start: bs, count: Int(frameCount)).map {
                    guard let symbol = $0 else {
                        return "<null>"
                    }
                    return String(cString: symbol)
                }
            }
        }
        return symbols.joined(separator: "\n")
    }
    
    /**
     *  这里主要利用了 Thread 和 pThread 共用一个Name的特性，找到对应 thread 的内核线程 thread_t
     *  但是主线程不行，主线程设置Name无效.
     */
fileprivate static func machThread(from thread: Thread) -> thread_t {
    var count: mach_msg_type_number_t = 0
    var threads: thread_act_array_t!
    guard task_threads(mach_task_self_, &(threads), &count) == KERN_SUCCESS else {
        return mach_thread_self()
    }

    if thread.isMainThread {
        return main_thread_t ?? mach_thread_self()
    }
    
    let originName = thread.name

    for i in 0..<count {
        let machThread = threads[Int(i)]
        if let p_thread = pthread_from_mach_thread_np(machThread) {
            var name: [Int8] = Array<Int8>(repeating: 0, count: 256)
            pthread_getname_np(p_thread, &name, name.count)
            if thread.name == String(cString: name) {
                thread.name = originName
                return machThread
            }
        }
    }

    thread.name = originName
    return mach_thread_self()
}
    
    // MARK: Address resolution and swift demangle
    
    private static func getSymbol(address: UInt, index: Int) -> String {
        var info = dl_info()
        dladdr(UnsafeRawPointer(bitPattern: address), &info)
        let symbol = symbol(info: info)
        let image = image(info: info)
        let offset = offset(info: info, address: address)
        let demangledSymbol = stdlib_demangleName(symbol)
        return image.utf8CString.withUnsafeBufferPointer { (imageBuffer: UnsafeBufferPointer<CChar>) -> String in
            #if arch(x86_64) || arch(arm64)
            return String(format: "%-4ld%-35s 0x%016llx %@ + %ld", index, UInt(bitPattern: imageBuffer.baseAddress), address, demangledSymbol, offset)
            #else
            return String(format: "%-4d%-35s 0x%08lx %@ + %d", index, UInt(bitPattern: imageBuffer.baseAddress), address, demangledSymbol, offset)
            #endif
        }
    }
    
    private static func stdlib_demangleName(_ mangledName: String) -> String {
        return mangledName.utf8CString.withUnsafeBufferPointer {
            (mangledNameUTF8CStr) in

            let demangledNamePtr = stdlib_demangleImpl(
                mangledName: mangledNameUTF8CStr.baseAddress,
                mangledNameLength: UInt(mangledNameUTF8CStr.count - 1),
                outputBuffer: nil,
                outputBufferSize: nil,
                flags: 0)

            if let demangledNamePtr = demangledNamePtr {
                let demangledName = String(cString: demangledNamePtr)
                free(demangledNamePtr)
                return demangledName
            }
            return mangledName
        }
    }
    
    /// thanks to https://github.com/mattgallagher/CwlUtils/blob/master/Sources/CwlUtils/CwlAddressInfo.swift
    /// returns: the "image" (shared object pathname) for the instruction
    private static func image(info: dl_info) -> String {
        if let dli_fname = info.dli_fname, let fname = String(validatingUTF8: dli_fname), let _ = fname.range(of: "/", options: .backwards, range: nil, locale: nil) {
            return (fname as NSString).lastPathComponent
        } else {
            return "???"
        }
    }

    /// returns: the symbol nearest the address
    private static func symbol(info: dl_info) -> String {
        if let dli_sname = info.dli_sname, let sname = String(validatingUTF8: dli_sname) {
            return sname
        } else if let dli_fname = info.dli_fname, let _ = String(validatingUTF8: dli_fname) {
            return image(info: info)
        } else {
            return String(format: "0x%1x", UInt(bitPattern: info.dli_saddr))
        }
    }

    /// returns: the address' offset relative to the nearest symbol
    private static func offset(info: dl_info, address: UInt) -> Int {
        if let dli_sname = info.dli_sname, let _ = String(validatingUTF8: dli_sname) {
            return Int(address - UInt(bitPattern: info.dli_saddr))
        } else if let dli_fname = info.dli_fname, let _ = String(validatingUTF8: dli_fname) {
            return Int(address - UInt(bitPattern: info.dli_fbase))
        } else {
            return Int(address - UInt(bitPattern: info.dli_saddr))
        }
    }
    
}
