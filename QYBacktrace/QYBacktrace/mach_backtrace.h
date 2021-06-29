//
//  mach_backtrace.h
//  QYBacktrace
//
//  Created by Joey on 2021/6/29.
//

#ifndef mach_backtrace_h
#define mach_backtrace_h

#include <mach/mach.h>

/**
 *  fill a backtrace call stack array of given thread
 *
 *  @param thread   mach thread for tracing
 *  @param stack    caller space for saving stack trace info
 *  @param maxSymbols max stack array count
 *
 *  @return call stack address array
 */
int mach_backtrace(thread_t thread, void** stack, int maxSymbols);

#endif /* mach_backtrace_h */
