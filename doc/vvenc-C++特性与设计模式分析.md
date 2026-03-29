# vvenc C++ 特性与设计模式分析

这份文档不讨论编码算法，而是专门从代码层面总结 `vvenc` 中常见的 C++ 用法、工程风格和设计模式。目标是帮助读代码时更快建立“这段实现为什么这样写”的判断框架。

## 1. 总体风格

`vvenc` 的代码风格可以概括为：

- 现代 C++ 特性会用，但整体仍然偏性能导向和工程保守
- 内存与对象生命周期控制非常显式
- 大量使用“轻量视图 + owning storage”分层
- 并发不是用通用线程池封装，而是用定制线程池和同步原语
- 设计模式更多是“工程模式”，而不是教科书式抽象框架

从代码气质上看，它更像：

- 一套高性能编解码器工程代码

而不是：

- 追求高度抽象和泛型优雅的现代 C++ 库

## 2. 常见 C++ 语言特性

## 2.1 模板与类型泛化

`vvenc` 大量使用模板，但大多是“低层容器与性能内核模板”，不是复杂 TMP 框架。

典型例子：

- [Buffer.h](/Users/skl/reading/hlpvvc/vvenc/source/Lib/CommonLib/Buffer.h)
  - `template<typename T> struct AreaBuf`
  - `template<typename T> struct UnitBuf`
- [TypeDef.h](/Users/skl/reading/hlpvvc/vvenc/source/Lib/CommonLib/TypeDef.h)
  - `template<typename T, size_t N> class static_vector`
  - `template<typename T, size_t SIZE> class dynamic_cache`

这种模板使用有几个特点：

- 用模板把“像素、系数、运动信息”等同构二维数据结构统一起来
- 减少重复代码
- 保持编译期分派，不引入额外虚函数开销

典型思想：

```cpp
AreaBuf<Pel>        -> 像素缓冲
AreaBuf<TCoeff>     -> 系数缓冲
AreaBuf<MotionInfo> -> 运动信息缓冲
```

这里体现的是一种“泛型数据容器”风格。

## 2.2 类型别名与语义化 typedef / using

`vvenc` 很多核心类型都通过 `typedef` 或 `using` 语义化。

例如：

- `typedef AreaBuf<Pel> PelBuf`
- `typedef UnitBuf<Pel> PelUnitBuf`
- `typedef std::list<Picture*> PicList`
- `using MergeIdxPair = std::array<int8_t, 2>`

作用：

- 让底层通用模板在业务层看起来更像领域模型
- 降低阅读时的模板噪声

这是一种很典型的“领域语义包装通用结构”的做法。

## 2.3 继承与运行时多态

`vvenc` 里并不回避传统虚函数。

典型例子：

- [EncStage.h](/Users/skl/reading/hlpvvc/vvenc/source/Lib/EncoderLib/EncStage.h)

```cpp
virtual void initPicture( Picture* pic ) = 0;
virtual void processPictures( const PicList& picList, AccessUnitList& auList, PicList& doneList, PicList& freeList ) = 0;
```

然后：

- `PreProcess : public EncStage`
- `MCTF : public EncStage`
- `EncGOP : public EncStage`

这说明 `vvenc` 会在“pipeline stage”这种天然适合抽象的边界上使用运行时多态。

特点：

- 抽象边界比较稳定时，使用虚函数
- 性能热点内部逻辑，更多使用普通函数、模板或函数指针

这是一个很实用的取舍。

## 2.4 函数对象与回调

`vvenc` 使用 `std::function` 主要用于“边界回调”而不是“核心热路径”。

典型例子：

- [EncLib.h](/Users/skl/reading/hlpvvc/vvenc/source/Lib/EncoderLib/EncLib.h)
- [EncGOP.h](/Users/skl/reading/hlpvvc/vvenc/source/Lib/EncoderLib/EncGOP.h)

例如重建 YUV 回调：

```cpp
std::function<void( void*, vvencYUVBuffer* )> m_recYuvBufFunc;
```

这种设计适合：

- API 边界
- 事件通知
- 外部注入行为

但在 SIMD/像素处理热路径里，`vvenc` 更常用的是：

- 裸函数指针
- 模板实例化

比如：

- `PelBufferOps`
- `MCTF` 中的 `m_applyFrac`、`m_motionErrorLumaInt8`

这体现了“边界灵活，热点保守”的风格。

## 2.5 `std::atomic`、`std::mutex`、`std::condition_variable`

`vvenc` 的并发控制大量使用标准库同步原语。

典型位置：

- [NoMallocThreadPool.h](/Users/skl/reading/hlpvvc/vvenc/source/Lib/Utilities/NoMallocThreadPool.h)
- [EncSlice.h](/Users/skl/reading/hlpvvc/vvenc/source/Lib/EncoderLib/EncSlice.h)
- [EncGOP.h](/Users/skl/reading/hlpvvc/vvenc/source/Lib/EncoderLib/EncGOP.h)

用途包括：

- 线程池任务调度
- barrier / wait counter
- CTU 状态推进
- 帧编码完成通知

比如：

- `std::atomic<TaskState>`
- `std::atomic_bool`
- `std::mutex`
- `std::condition_variable`

这说明 `vvenc` 的多线程不是“黑盒并行框架”，而是直接构建在基础同步原语上的定制实现。

## 2.6 局部 lambda 任务

`vvenc` 在多线程任务派发时，经常使用局部 lambda。

例如 `EncGOP::xEncodePicture()` 里：

```cpp
static auto finishTask = []( int, FinishTaskParam* param ) {
  ...
  return true;
};
```

这种写法的好处是：

- 任务逻辑和提交位置靠得很近
- 可读性比拆到单独静态函数更强
- 又能适配线程池需要的函数签名

这是比较典型的“现代 C++ + 传统系统代码”混合风格。

## 2.7 删除拷贝 / 移动，显式控制语义

`vvenc` 里很多同步对象和资源对象会显式禁用拷贝与移动。

例如：

- `WaitCounter`
- `Barrier`
- `BlockingBarrier`

常见写法：

```cpp
WaitCounter( const WaitCounter & ) = delete;
WaitCounter( WaitCounter && )      = delete;
WaitCounter &operator=( const WaitCounter & ) = delete;
```

这是一种典型的“语义约束型 C++”写法：

- 不允许误复制同步对象
- 在类型层面防止错误使用

## 2.8 RAII，但不是完全依赖智能指针

`vvenc` 使用 RAII，但并不完全依赖 `std::unique_ptr` / `std::shared_ptr`。

例如：

- `PelStorage` 在析构中负责释放自己的内存
- `AccessUnitList` 在析构或 `clearAu()` 中释放内部 NAL
- `NoMallocThreadPool::PThread` 利用 RAII 维护线程对象

但另一方面，源码里依然有很多：

- `new`
- `delete`
- `delete[]`

说明它采用的是：

- RAII 思维
- 显式所有权控制

而不是完全依赖“全仓库智能指针化”。

这在高性能老牌工程里很常见。

## 3. 常见设计模式

## 3.1 Pipeline / Stage 模式

这是 `vvenc` 最明显的架构模式之一。

核心类：

- [EncStage.h](/Users/skl/reading/hlpvvc/vvenc/source/Lib/EncoderLib/EncStage.h)

派生类：

- `PreProcess`
- `MCTF`
- `EncGOP`

特征：

- 每个 stage 有自己的 `m_procList` / `m_freeList`
- stage 之间通过 `linkNextStage()` 串起来
- 每个 stage 都实现：
  - `initPicture()`
  - `processPictures()`

这非常典型地体现了：

- Pipeline 模式
- 也带一点 Template Method 味道

其中：

- 父类定义通用调度骨架
- 子类填充具体处理逻辑

## 3.2 Template Method 模式

`EncStage` 就是一个很典型的 Template Method。

父类控制：

- 队列管理
- flush 行为
- picture 创建和回收
- 向下一个 stage 传递

子类实现：

- `initPicture`
- `processPictures`

也就是说：

- 算法框架固定
- 具体步骤由派生类决定

## 3.3 Object Pool / 对象池模式

`vvenc` 出于性能考虑，明显使用对象池。

典型例子：

- `EncGOP` 中的 `m_freePicEncoderList`
- `EncStage` 中的 `m_freeList`
- `dynamic_cache`
- `XUCache`

比如 `EncGOP` 会预分配多个 `EncPicture`：

```cpp
EncPicture* picEncoder = new EncPicture;
m_freePicEncoderList.push_back( picEncoder );
```

编码时取一个空闲对象，用完再放回池中，而不是频繁 new/delete。

这属于非常经典的对象池模式，目的很明确：

- 避免高频分配
- 提升 cache locality
- 让多线程下资源复用更可控

## 3.4 Flyweight / 共享数据模式

典型例子：

- `PicShared`

作用：

- 原始输入缓冲和前处理元数据不直接塞进每个 `Picture` 的独立所有权里
- 而是通过 `PicShared` 被多个阶段共享

这有明显的 Flyweight 思想：

- 把可共享的大对象抽出来
- 减少重复拷贝和重复持有

## 3.5 Strategy 模式

`vvenc` 很多热点内核并不是通过虚函数 Strategy，而是通过：

- 函数指针
- 配置开关
- SIMD 初始化分派

典型例子：

- `PelBufferOps`
- `MCTF`

如：

- `m_motionErrorLumaInt8`
- `m_applyFrac`
- `m_applyBlock`

在初始化阶段根据平台能力绑定不同实现。  
这本质上就是一种 Strategy 模式，只是实现方式偏底层、偏性能。

## 3.6 Factory / Parameter Set 分配模式

在参数集和一些内部对象上，`vvenc` 使用“集中分配接口”而不是随处构造。

例如：

- `ParameterSetMap<SPS>::allocatePS()`
- `ParameterSetMap<PPS>::allocatePS()`

这种方式带一点工厂模式味道：

- 创建入口集中
- 对象生命周期与容器绑定
- 更便于做索引和映射管理

## 3.7 Cache 模式

`vvenc` 中有明显的缓存对象设计。

典型例子：

- `CtxCache`
- `XUCache`
- `dynamic_cache`

这些缓存主要服务于：

- 上下文对象重用
- 编码单元 / 变换单元重用
- 减少细粒度对象分配

这属于非常典型的工程优化模式，不一定是 GoF 教材里的名字，但设计意图非常明确。

## 3.8 Producer Consumer / 任务队列模式

`NoMallocThreadPool` 和各类 barrier / counter 共同构成了一个定制任务系统。

典型特征：

- 任务队列
- 工作线程
- barrier 依赖
- WaitCounter 完成计数

这本质上是：

- Producer Consumer
- 任务图上带轻量依赖的并发执行模型

只是实现上高度定制，目标是：

- 无额外 malloc
- 低调度开销
- 更可控的同步

## 4. 性能导向的代码风格

## 4.1 owning 对象与 view 对象分离

典型例子：

- `PelStorage` 持有内存
- `PelBuf` / `PelUnitBuf` 只做视图

这是一种很成熟的高性能设计：

- 避免到处拷贝大块像素数据
- 允许子区域操作只传视图

## 4.2 避免高频堆分配

方式包括：

- 对象池
- `dynamic_cache`
- `NoMallocThreadPool`
- 复用 `Picture` / `EncPicture`

这说明 `vvenc` 对“分配开销”非常敏感。

## 4.3 热路径尽量不走虚函数

热点代码里更常见：

- 模板
- 函数指针
- 普通函数

而不是：

- 深层继承树 + 大量虚调度

这是编解码器很常见的写法。

## 4.4 显式数据布局

大量核心结构都非常“扁平”：

- POD-like 成员
- 连续数组
- 手动 stride
- 显式大小与坐标

这有利于：

- cache 命中
- SIMD
- 边界控制

## 5. 读 `vvenc` 代码时的几个识别技巧

## 5.1 看到 `Buf`，先问自己它是不是 view

通常：

- `PelBuf`
- `PelUnitBuf`
- `AreaBuf`

都更像视图，而不是所有者。

## 5.2 看到 `Storage` / `Cache` / `List`，先想所有权和复用

例如：

- `PelStorage`
- `CompStorage`
- `dynamic_cache`
- `m_freePicEncoderList`

它们通常涉及：

- 内存所有权
- 对象池
- 生命周期复用

## 5.3 看到 `init + set function pointer`，先想到 Strategy

例如 SIMD 初始化后绑定：

- 某个函数指针指向 SSE/AVX/NEON/标量版本

这几乎就是 `vvenc` 里的高性能策略切换套路。

## 5.4 看到 `EncStage` 派生类，先想到 pipeline

例如：

- `PreProcess`
- `MCTF`
- `EncGOP`

它们通常不是孤立模块，而是在整条编码流水线上协作。

## 6. 一句话总结

`vvenc` 的 C++ 代码风格本质上是“性能优先的工程化现代 C++”。它会使用模板、lambda、`std::function`、原子与条件变量等现代特性，但真正的核心不是语言炫技，而是围绕数据布局、对象复用、并行调度和热点路径开销，组合出一套务实的高性能实现。  
