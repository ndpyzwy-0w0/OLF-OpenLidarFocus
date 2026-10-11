#pragma once
using SemaphoreHandle_t=int;
inline int xSemaphoreCreateRecursiveMutex() { return 1; }
inline int stateLockDepth=0;
inline void xSemaphoreTakeRecursive(int,unsigned) { ++stateLockDepth; }
inline void xSemaphoreGiveRecursive(int) { --stateLockDepth; }
