# Swift堆栈信息获取 

本项目完整代码：[QYBacktrace](https://github.com/FightingJoey/QYBacktrace)，如果对你有帮助欢迎 star ~

OC版本的可以参考张星宇的 [BSBacktraceLogger](https://github.com/bestswifter/BSBacktraceLogger)

## 什么是线程调用栈

**调用栈**，也称为执行栈、控制栈、运行时栈与机器栈，是计算机科学中存储运行子程序的重要的数据结构，主要存放返回地址、本地变量、参数及环境传递，用于跟踪每个活动的子例程在完成执行后应该返回控制的点。简单的来说，就是存放当前线程的调用函数信息的地方。它们以一种栈的结构进行存储，方便函数往下调用，往上返回。

## 如何获取线程调用栈

`Thread` 提供了 `Thread.callstackSymbols` 来获取当前线程的调用栈，也可以通过 `backtrace/backtrace_symbols` 接口获取，但**只能获取当前线程的调用栈**，无法获取其他线程的调用栈。

那么能不能获取到所有线程的堆栈信息呢？目前有两种方案：

- 通过 mach thread (目前主流方案)
- 通过 Signal handle (信号处理) 

## 系统方法获取当前线程调用栈

### Thread.callstackSymbols

```swift
DispatchQueue.global().async {
    let symbols = Thread.callStackSymbols
    for symbol in symbols {
    		print(symbol.description)
    }
}
```

### backtrace_symbols

OC版本

```objective-c
+ (NSArray *)backtrace
{
    //定义一个指针数组
    void* callstack[128];
    //该函数用于获取当前线程的调用堆栈,获取的信息将会被存放在callstack中。
    //参数128用来指定callstack中可以保存多少个void* 元素。
    //函数返回值是实际获取的指针个数,最大不超过128大小在callstack中的指针实际是从堆栈中获取的返回地址,每一个堆栈框架有一个返回地址。
    int frames = backtrace(callstack, 128);
    //backtrace_symbols将从backtrace函数获取的信息转化为一个字符串数组.
    //参数callstack应该是从backtrace函数获取的数组指针,frames是该数组中的元素个数(backtrace的返回值)
    //函数返回值是一个指向字符串数组的指针,它的大小同callstack相同.每个字符串包含了一个相对于callstack中对应元素的可打印信息.
    char **strs = backtrace_symbols(callstack, frames);
  
    NSMutableArray *backtrace = [NSMutableArray arrayWithCapacity:frames];
    for (int i=0; i < frames; i++)
    {
        [backtrace addObject:[NSString stringWithUTF8String:strs[i]]];
    }
    //注意释放
    free(strs);
    return backtrace;
}
```

Swift版本

```swift
@_silgen_name("backtrace_symbols")
fileprivate func backtrace_symbols(_ stack: UnsafePointer<UnsafeMutableRawPointer?>!, _ frame: Int32) -> UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>!

@_silgen_name("backtrace")
fileprivate func backtrace(_ stack: UnsafePointer<UnsafeMutableRawPointer?>!, _ size: Int32) -> Int32

func getBacktrace() -> String {
    let maxSize: Int32 = 128
    let addrs = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(maxSize))
    defer { addrs.deallocate() }
    let count = backtrace(addrs, maxSize)
    var symbols: [String] = []
    if let bs = backtrace_symbols(addrs, count) {
        symbols = UnsafeBufferPointer(start: bs, count: Int(count)).map {
            guard let symbol = $0 else {
                return "<null>"
            }
            return String(cString: symbol)
        }
    }
    return symbols.joined(separator: "\n")
}
```

> `@_silgen_name` 的作用就是调用关键字下面的函数时候实际上调用的是关键字包装的函数。
>
> 注意：关键字和下面声明的函数要一上一下，中间不能有其他函数隔开。

## 通过 mach thread 获取线程调用栈

### 获取所有线程的调用栈

1. `mach` 提供一个系统方法 `task_threads`，该方法可以获取当前进程的所有线程。所有的线程被保存在 `threads` 数组中。

   ```swift
   var count: mach_msg_type_number_t = 0
   var threads: thread_act_array_t!
   let kert = task_threads(mach_task_self_, &(threads), &count)
   ```

> 注意：任务与进程的概念是一一对应的，即iOS系统进程(对应应用)都在底层关联了一个 `Mach` 任务对象，因此可以通过 `mach_task_self_` 来获取当前进程对应的任务对象；

> 这里的线程为最底层的 `Mach` 内核线程，`posix` 接口中的线程 `pthread` 与内核线程一一对应，是内核线程的抽象，`NSThread` 线程是对 `pthread` 的面向对象的封装。

2. `mach` 还提供了一个方法 `thread_get_state` ，该方法可以获取当前线程的上下文信息，信息填充在 `_STRUCT_MCONTEXT` 类型的参数中。

   > 这个方法中有两个参数（THREAD_STATE_COUNT、THREAD_STATE_FLAVOR）随着 CPU 架构的不同而改变，因此需要注意不同 CPU 之间的区别。

   ```c
   _STRUCT_MCONTEXT machineContext;
   mach_msg_type_number_t stateCount = THREAD_STATE_COUNT;
   kern_return_t kret = thread_get_state(thread, THREAD_STATE_FLAVOR, (thread_state_t)&(machineContext.__ss), &stateCount);
   if (kret != KERN_SUCCESS) {
     	return 0;
   }
   ```

3. 在 `_STRUCT_MCONTEXT` 类型的结构体中，存储了当前线程的 `Stack Pointer` 和最顶部栈帧的 `Frame Pointer`，从而获取到了整个线程的调用栈。

   ```c
   int mach_backtrace(thread_t thread, void** stack, int maxSymbols) {
       _STRUCT_MCONTEXT machineContext;
       mach_msg_type_number_t stateCount = THREAD_STATE_COUNT;
   
       kern_return_t kret = thread_get_state(thread, THREAD_STATE_FLAVOR, (thread_state_t)&(machineContext.__ss), &stateCount);
       if (kret != KERN_SUCCESS) {
           return 0;
       }
   
       int i = 0;
       // 获取到最顶部栈帧的pc，即当前函数指针
       stack[i] = (void *)machineContext.__ss.__programCounter;
       ++i;
   #if defined(__arm__) || defined (__arm64__)
       // 获取到最顶部栈帧的LR，即返回指针
       stack[i] = (void *)machineContext.__ss.__lr;
       ++i;
   #endif
       // 获取到当前的FP，**表示指向指针的指针，FP是一个指向上一个栈帧的FP指针的指针
       void **currentFramePointer = (void **)machineContext.__ss.__framePointer;
       while (i < maxSymbols) {
           // 获取到上一个栈帧的FP
           void **previousFramePointer = *currentFramePointer;
           if (!previousFramePointer) break;
           // 将上一个栈帧的LR保存在call stack address array中
           stack[i] = *(currentFramePointer+1);
           currentFramePointer = previousFramePointer;
           ++i;
       }
       return i;
   }
   ```

   ARM64 栈帧架构

   ![ARM64 架构](https://tva1.sinaimg.cn/large/008i3skNgy1gry3mb1b43j31lk0u0jw8.jpg)

    X86_64 栈帧架构

   ![ X86_64架构](https://tva1.sinaimg.cn/large/008i3skNgy1gry3ob5j6nj31c50u0q83.jpg)

   由上面的两张图可以看到，FP指向的其实是栈帧中保存的上一个栈帧的FP，而对其地址向上偏移8个字节，就是返回指针LR，通过 FP 的不断递归，我们就可以获取到整个线程所有的栈帧，然后通过每个栈帧中的 LR，来获取到函数指针，即获取到了整个线程的函数调用栈。

   > 这一部分的理解花了我大量的时间，主要是网上的资料不明确，不过我也不是很确定自己的想法是否正确，目前看来和代码逻辑是一致的，如果有哪位大佬有更好的理解，欢迎指正！

4. 获取到所有整个线程调用栈的函数地址数组后，有两种处理方案：

   1. 调用系统的C方法 `backtrace_symbols` 解析符号信息，之后将其中的符号转化为字符串。
   2. 通过 dladdr 函数和 dl_info 函数获得某个地址的符号信息，之后将其转化为字符串，并进行Swift符号重整。

   > 完整代码有些长，请到我的GitHub查看

### 获取某个线程的调用栈

有时我们不需要获取所有线程的调用栈信息，只想获取某个线程的调用栈信息。但是 Thread 实例无法获取 `thread_state_t` 信息，也没有接口可以获取 `callstackSymbols`。

那么我们现在要做的就是：`thread` → `pthread` → `mach thread`

但是苹果并没有提供 `thread` → `pthread` 方法，而 `pthread` 和 `mach thread` 之间可以相互转化，那么关键就在于看看 `pthread` 和 `thread` 之间有没有什么联系，张星宇提出了一种方案，根据 `name` 来判断 `thread` 和 `pthread` 是否对应。

现在只需要给  `thread` 设置一个 `name`，然后遍历所有的 `mach thread`，如果名字相同，那么就可以确定该 `mach thread` 对应实例 `thread` 了。确定了 `mach thread`，我们就可以获取到调用栈信息了。

还有一个问题，就是主线程设置 `name` 无效，所以需要特殊处理。

```swift
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
```

## 说明

Xcode 的调试输出不稳定，有时候存在调用 `print` 但没有输出结果的情况，建议前往 **控制台** 中根据设备的 UUID 查看完整输出。

真机调试和使用 Release 模式时，为了优化，某些符号表并不在内存中，而是存储在磁盘上的 dSYM 文件中，无法在运行时解析，因此符号名称显示为 `<redacted>`。

## 参考文章

[iOS开发--探究iOS线程调用栈及符号化](https://www.ancii.com/ace3ewpyg/)

[通过mach thread捕获任意线程调用栈信息-Swift](https://juejin.cn/post/6844904176237936653#heading-5)

[iOS获取任意线程调用栈](https://juejin.cn/post/6844903944842395656)

[通过Signal handling(信号处理)获取任意线程调用栈](https://juejin.cn/post/6844903919617835021)



