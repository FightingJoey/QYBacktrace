//
//  mach_backtrace.c
//  QYBacktrace
//
//  Created by Joey on 2021/6/29.
//

#include "mach_backtrace.h"
#include <stdio.h>
#include <stdlib.h>
#include <machine/_mcontext.h>

// macro `MACHINE_THREAD_STATE` shipped with system header is wrong..
#if defined __i386__
#define THREAD_STATE_FLAVOR x86_THREAD_STATE
#define THREAD_STATE_COUNT  x86_THREAD_STATE_COUNT
#define __framePointer      __ebp
#define __programCounter    __eip
#define __stackPointer      __esp

#elif defined __x86_64__
#define THREAD_STATE_FLAVOR x86_THREAD_STATE64
#define THREAD_STATE_COUNT  x86_THREAD_STATE64_COUNT
#define __framePointer      __rbp
#define __programCounter    __rip
#define __stackPointer      __rsp

#elif defined __arm__
#define THREAD_STATE_FLAVOR ARM_THREAD_STATE
#define THREAD_STATE_COUNT  ARM_THREAD_STATE_COUNT
#define __framePointer      __r[7]
#define __programCounter    __pc
#define __stackPointer      __sp

#elif defined __arm64__
#define THREAD_STATE_FLAVOR ARM_THREAD_STATE64
#define THREAD_STATE_COUNT  ARM_THREAD_STATE64_COUNT
#define __framePointer      __fp
#define __programCounter    __pc
#define __stackPointer      __sp

#else
#error "Current CPU Architecture is not supported"
#endif

/**
 *  fill a backtrace call stack array of given thread
 *
 *  Stack frame structure for x86/x86_64:
 *
 *    | ...                   |
 *    +-----------------------+ hi-addr     ------------------------
 *    | func0 ip              |
 *    +-----------------------+
 *    | func0 bp              |--------|     stack frame of func1
 *    +-----------------------+        v
 *    | saved registers       |  bp <- sp
 *    +-----------------------+   |
 *    | local variables...    |   |
 *    +-----------------------+   |
 *    | func2 args            |   |
 *    +-----------------------+   |         ------------------------
 *    | func1 ip              |   |
 *    +-----------------------+   |
 *    | func1 bp              |<--+          stack frame of func2
 *    +-----------------------+
 *    | ...                   |
 *    +-----------------------+ lo-addr     ------------------------
 *
 *  list we need to get is `ip` from bottom to top
 *
 *
 *  Stack frame structure for arm/arm64:
 *
 *    | ...                   |
 *    +-----------------------+ hi-addr     ------------------------
 *    | func0 lr              |
 *    +-----------------------+
 *    | func0 fp              |--------|     stack frame of func1
 *    +-----------------------+        v
 *    | saved registers       |  fp <- sp
 *    +-----------------------+   |
 *    | local variables...    |   |
 *    +-----------------------+   |
 *    | func2 args            |   |
 *    +-----------------------+   |         ------------------------
 *    | func1 lr              |   |
 *    +-----------------------+   |
 *    | func1 fp              |<--+          stack frame of func2
 *    +-----------------------+
 *    | ...                   |
 *    +-----------------------+ lo-addr     ------------------------
 *
 *  when function return, first jump to lr, then restore lr
 *  (namely first address in list is current lr)
 *
 *  fp (frame pointer) is r7 register under ARM and fp register in ARM64
 *  reference: iOS ABI Function Call Guide https://developer.apple.com/library/ios/documentation/Xcode/Conceptual/iPhoneOSABIReference/Articles/ARMv7FunctionCallingConventions.html#//apple_ref/doc/uid/TP40009022-SW1
 *
 *  @param thread   mach thread for tracing
 *  @param stack    caller space for saving stack trace info
 *  @param maxSymbols max stack array count
 *
 *  @return call stack address array
 */
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
