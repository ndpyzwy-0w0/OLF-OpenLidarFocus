#pragma once
using SemaphoreHandle_t=int;
inline int xSemaphoreCreateRecursiveMutex() { return 1; }
inline void xSemaphoreTakeRecursive(int,unsigned) {}
inline void xSemaphoreGiveRecursive(int) {}
