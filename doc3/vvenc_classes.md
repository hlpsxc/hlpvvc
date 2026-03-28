# vvenc 主要类分析文档

## 概述

vvenc 是一个符合 VVC（Versatile Video Coding / H.266）标准的视频编码器。其源码位于 `vvenc/source/Lib/` 目录下，分为三个主要模块：

- **CommonLib/** — 编解码共用组件（预测、变换、滤波等）
- **EncoderLib/** — 编码器专用组件（GOP/Slice/CU 编码、码率控制等）
- **vvenc/** — 对外暴露的公共 SDK 接口

---

## 编码流水线总览

```
用户调用
VVEncImpl::encode()
    └─ EncLib::encodePicture()
           ├─ PreProcess        (视觉活动分析、场景切换检测)
           ├─ MCTF              (运动补偿时域滤波，可选)
           ├─ EncGOP (预编码器) (预分析)
           └─ EncGOP (主编码器)
                  └─ EncPicture::compressPicture()
                         ├─ EncSlice          (多线程 Slice 编码)
                         │    └─ EncCu        (编码单元模式决策)
                         │         ├─ IntraSearch  (帧内预测搜索)
                         │         ├─ InterSearch  (帧间预测 + 运动估计)
                         │         └─ TrQuant      (变换 + 量化)
                         ├─ LoopFilter        (去块滤波)
                         ├─ EncAdaptiveLoopFilter (ALF)
                         └─ EncSampleAdaptiveOffset (SAO)
                                → CABACWriter  (熵编码输出)
RateCtrl 贯穿整个流水线，负责码率反馈与 QP 调整
```

---

## 一、公共接口层

### 1. VVEncImpl

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/vvenc/vvencimpl.h` |
| 职责 | 对外编码器接口，管理编码状态机 |

**主要方法：**
- `init()` — 使用配置参数初始化编码器
- `encode()` — 将 YUV 图像编码为 Access Unit（码流片段）
- `getParameterSets()` — 获取 SPS/PPS/VPS 参数集
- `reconfig()` — 运行时动态重配置
- `uninit()` — 释放所有资源

**状态机：** UNINITIALIZED → INITIALIZED → ENCODING → FLUSHING → FINALIZED

**组合关系：** 内部持有 `EncLib` 完成实际编码工作。

---

### 2. VVEncCfg / EncCfg

| 属性 | 内容 |
|------|------|
| 文件 | `include/vvenc/vvencCfg.h`，`source/Lib/EncoderLib/EncCfg.h` |
| 职责 | 存储全部编码器配置参数 |

**主要内容：**
- 视频分辨率、帧率、位深
- QP 设置、码率控制参数
- GOP 结构（最大支持 64 帧 GOP，`VVENC_MAX_GOP=64`）
- ALF、SAO、MCTF 开关
- 并行处理参数
- 电影颗粒配置（`vvencFG` 结构体）

**关键常量：**
```
VVENC_MAX_GOP       = 64   // 最大 GOP 大小
VVENC_MAX_TLAYER    = 7    // 最大时域层数
VVENC_MAX_NUM_REF_PICS = 29 // 最大参考帧数
```

---

## 二、编码器核心层

### 3. EncLib

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/EncoderLib/EncLib.h` |
| 职责 | 编码器引擎总协调，管理完整编码流水线 |

**主要方法：**
- `initEncoderLib()` — 初始化所有编码组件
- `encodePicture()` — 将图像送入编码流水线
- `getParameterSets()` — 导出参数集
- `printSummary()` — 输出编码统计信息

**组合关系：**
```
EncLib
  ├─ RateCtrl*            码率控制
  ├─ PreProcess*          预处理阶段
  ├─ MCTF*                运动补偿时域滤波
  ├─ EncGOP* m_preEncoder 预编码 GOP
  ├─ EncGOP* m_gopEncoder 主编码 GOP
  ├─ vector<EncStage*>    并行流水线各阶段
  ├─ NoMallocThreadPool*  线程池
  └─ deque<AccessUnitList> 输出码流队列
```

---

### 4. EncGOP

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/EncoderLib/EncGOP.h` |
| 职责 | 以 GOP 为单位编码；负责 SPS/PPS/VPS 写入 |

**主要方法：**
- `compressSlice()` — 编码整个 Slice
- `encodeSlice()` — 逐 Slice 编码
- `selectReferencePictureList()` — 选择参考图像

**组合关系：**
```
EncGOP
  ├─ EncPicture           图像编码器
  ├─ HLSWriter            高层语法写入
  ├─ SEIWriter/SEIEncoder SEI 消息处理
  ├─ EncReshape           色域重映射 (LMCS)
  ├─ EncHRD               HRD 合规处理
  ├─ ParameterSetMap<SPS/PPS> 参数集管理
  ├─ VPS, DCI             视频/解码能力参数
  └─ RateCtrl*            码率控制
```

---

### 5. EncPicture

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/EncoderLib/EncPicture.h` |
| 职责 | 单图像压缩，协调 Slice 编码和环路滤波 |

**主要方法：**
- `compressPicture()` — 主压缩流程
- `finalizePicture()` — 后处理与收尾

**组合关系：**
```
EncPicture
  ├─ EncSlice                 Slice 编码器
  ├─ LoopFilter               去块滤波
  ├─ EncAdaptiveLoopFilter    ALF 处理
  ├─ CABACWriter + BitEstimator 熵编码
  └─ RateCtrl*                码率控制接口
```

---

### 6. EncSlice

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/EncoderLib/EncSlice.h` |
| 职责 | Slice 编码，支持 CTU 级别多线程并行 |

**主要内容：**
- 按线程管理资源（每线程独立上下文）
- Tile-line 编码资源管理
- 使用原子变量 `ProcessCtuState` 跟踪处理状态

**任务类型：**
```
CTU_ENCODE → RESHAPE_LF_VER → LF_HOR → SAO_FILTER → ALF 操作 → FINISH_SLICE
```

---

### 7. EncCu

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/EncoderLib/EncCu.h` |
| 职责 | 编码单元（CU）级别模式决策，搜索最优编码模式 |

**关键数据结构：**
- `MergeItem` — 存储 Merge 候选结果
- `FastGeoCostList` / `GeoComboCostList` — 几何划分 Merge 代价追踪
- `GeoMergeCombo` — 几何 Merge 组合方案

**组合关系：**
```
EncCu
  ├─ IntraSearch      帧内模式搜索
  ├─ InterSearch      帧间预测与运动估计
  ├─ EncModeCtrl      模式控制与决策
  ├─ CABACWriter      熵编码
  └─ RateCtrl*        码率控制
```

---

### 8. EncModeCtrl

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/EncoderLib/EncModeCtrl.h` |
| 职责 | 控制需要测试的编码模式集合，实现快速决策 |

**关键枚举 `EncTestModeType`：**
```
MERGE_SKIP, INTER_ME, INTRA, IBC,
SPLIT_QT, SPLIT_BT_H, SPLIT_BT_V,
SPLIT_TT_H, SPLIT_TT_V, ...
```

---

## 三、预测模块

### 9. IntraSearch

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/EncoderLib/IntraSearch.h` |
| 继承 | `IntraPrediction` |
| 职责 | 搜索最优帧内预测模式 |

**关键数据结构：**
- `ModeInfo` — 存储帧内模式信息
- `ISPTestedModesInfo` — ISP（帧内子分区）测试状态
- `SortedPelUnitBufs<SORTED_BUFS>` — 排序像素缓冲区

---

### 10. IntraPrediction

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/CommonLib/IntraPrediction.h` |
| 职责 | 帧内预测基类，实现各种帧内预测模式 |

**主要功能：**
- 参考缓冲区管理
- PDPC（位置相关预测校正）
- MRL（多参考行）支持
- ISP（帧内子分区）模式支持
- X86/ARM SIMD 加速

---

### 11. InterSearch

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/EncoderLib/InterSearch.h` |
| 继承 | `InterPrediction` |
| 职责 | 运动估计与帧间预测模式搜索 |

**关键数据结构：**
- `BlkUniMvInfo` — 单向运动矢量信息
- `BlkUniMvInfoBuffer` — 运动矢量缓存环形缓冲区
- `BlkRecord` — 块级记录（消除冗余搜索）

**支持模式：** Merge / MMVD / CIIP / 仿射运动搜索

---

### 12. InterPrediction

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/CommonLib/InterPrediction.h` |
| 职责 | 帧间预测基类，含插值滤波 |

**主要功能：**
- `InterpolationFilter` — 插值滤波器
- BDOF（双向光流）梯度缓冲区
- PROF（基于光流的预测精化）支持
- 仿射运动梯度场支持
- X86/ARM SIMD 加速

---

## 四、变换与量化

### 13. TrQuant

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/CommonLib/TrQuant.h` |
| 职责 | 正/反变换与量化 |

**主要方法：**
- `transformNxN()` — 正变换
- `invTransformNxN()` — 反变换
- `checktransformsNxN()` — 多变换模式测试

**组合关系：**
```
TrQuant
  └─ DepQuant*   依赖量化引擎
```

**支持特性：** LFNST（低频不可分变换）、ICT（整数色彩变换）、X86/ARM SIMD 加速

---

## 五、环路滤波模块

### 14. LoopFilter

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/CommonLib/LoopFilter.h` |
| 职责 | 去块滤波，消除块效应 |

**主要方法：**
- `calcFilterStrengthsCTU()` — 计算每个 CTU 的滤波强度
- `xDeblockArea()` — 对指定区域应用去块滤波

**静态数据：** `sm_tcTable`、`sm_betaTable` — QP 相关参数表

---

### 15. AdaptiveLoopFilter (ALF)

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/CommonLib/AdaptiveLoopFilter.h` |
| 职责 | 自适应环路滤波，提升重建图像质量 |

**关键内容：**
- `AlfClassifier` — 像素块分类结构
- 分类块大小：128×128
- 方向分类：HOR / VER / DIAG0 / DIAG1
- 4 个自适应裁剪值

---

### 16. SampleAdaptiveOffset (SAO)

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/CommonLib/SampleAdaptiveOffset.h` |
| 职责 | 样点自适应偏移滤波 |

**主要方法：**
- `init()` — 初始化 SAO
- `calcSaoStatisticsBo()` — 计算带偏移统计量

---

## 六、预处理与时域滤波

### 17. PreProcess

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/EncoderLib/PreProcess.h` |
| 继承 | `EncStage` |
| 职责 | 编码前预处理：视觉活动分析、场景切换检测、时域下采样 |

**主要功能：**
- 视觉活动检测与 QPA 处理
- 空间/时域活动量分析
- STA（静止区域）检测
- 场景切换检测

**组合关系：**
```
PreProcess
  ├─ GOPCfg         GOP 配置
  └─ BitAllocation  比特分配策略
```

---

### 18. MCTF

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/CommonLib/MCTF.h` |
| 继承 | `EncStage` |
| 职责 | 运动补偿时域滤波，改善压缩效率 |

**关键结构：**
- `MotionVector` — 运动矢量（含误差度量）
- `Array2D<T>` — 二维数组模板
- 参考范围：前后各 ±6 帧

---

## 七、码率控制

### 19. RateCtrl

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/EncoderLib/RateCtrl.h` |
| 职责 | 比特分配与 QP 调整，实现目标码率控制 |

**子类：**

| 子类 | 职责 |
|------|------|
| `EncRCSeq` | 序列级码率控制（目标/实际比特数、QP 校正） |
| `EncRCPic` | 图像级码率控制（目标比特、预测比特、QP 调整） |
| `TRCPassStats` | 第一遍扫描的逐帧统计（POC、QP、lambda、视觉活动、比特数、PSNR） |

**主要方法：**
- `create()` — 初始化码率控制
- `updateAfterPic()` — 编码后更新统计
- `clipTargetQP()` — 基于缓冲区状态调整 QP

---

## 八、熵编码

### 20. CABACWriter

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/EncoderLib/CABACWriter.h` |
| 继承 | `DeriveCtx` |
| 职责 | CABAC 上下文自适应算术熵编码 |

**主要方法：**
- `coding_tree()` — 编码编码树结构
- `coding_unit()` — 编码 CU 语法元素
- `coding_tree_unit()` — 编码 CTU
- `sao()` / `alf()` — 滤波参数熵编码

**组合关系：** 使用 `BinEncIf`（二进制编码器接口）

---

### 21. OutputBitstream

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/CommonLib/BitStream.h` |
| 职责 | 码流输出管理，支持比特级写入 |

**主要方法：**
- `write()` — 写入比特
- `writeAlignZero()` / `writeAlignOne()` — 字节对齐
- `getByteStream()` — 获取原始字节数据

---

## 九、率失真优化

### 22. RdCost

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/CommonLib/RdCost.h` |
| 职责 | 率失真代价计算 |

**关键结构：**
- `DistParam` — 失真参数（含函数指针）
- 加权预测支持
- X86/ARM SIMD 向量化距离函数

---

## 十、核心数据结构

### 23. Picture

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/CommonLib/Picture.h` |
| 职责 | 表示一帧编码图像及其全部元数据与像素缓冲区 |

**主要内容：**
- YUV 像素缓冲区（原始、重建、滤波后）
- `CodingStructure` — 层次化编码单元树
- `Slice` 向量 — Slice 级参数
- 参考图像列表（运动补偿用）
- 视觉活动度量（`PicVisAct`）
- APS 映射表
- MD5 校验哈希

---

### 24. CodingStructure

| 属性 | 内容 |
|------|------|
| 文件 | `source/Lib/CommonLib/CodingStructure.h` |
| 职责 | 编码单元与变换单元的层次树表示 |

**主要方法：**
- `addCU()` / `addTU()` — 添加编码/变换单元
- `getCU()` / `getTU()` — 按位置查询单元
- `traverseCUs()` / `traverseTUs()` — 树遍历迭代器

**关联：** 持有 SPS / PPS / APS 参数集指针

---

### 25. 单元层次结构

```
Area          — 矩形区域（位置 + 尺寸）
  └─ CompArea     — 分量区域（含色度格式处理）
       └─ UnitArea — 多分量区域（Y、Cb、Cr）
            ├─ CodingUnit (CU)    — 编码树叶节点
            └─ TransformUnit (TU) — 变换树叶节点
```

---

### 26. 运动信息结构

| 结构 | 说明 |
|------|------|
| `Mv` | 运动矢量（x, y 分量） |
| `MotionInfo` | 参考索引、运动矢量、Merge 标志 |
| `ReferencePictureList` | 短期 / 长期参考帧列表 |

---

### 27. 缓冲区管理

| 类 | 说明 |
|----|------|
| `PelStorage` | 像素数据存储（多分量） |
| `PelBuf` | 像素缓冲区视图（stride 感知） |
| `CoeffBuf` | 变换系数缓冲区 |

---

## 十一、类继承关系汇总

```
IntraPrediction
  └─ IntraSearch

InterPrediction（含 InterpolationFilter）
  └─ InterSearch

EncStage（抽象流水线阶段）
  ├─ PreProcess
  └─ MCTF

DeriveCtx
  └─ CABACWriter
```

---

## 十二、文件索引

| 类 | 头文件路径 |
|----|-----------|
| VVEncImpl | `source/Lib/vvenc/vvencimpl.h` |
| VVEncCfg | `include/vvenc/vvencCfg.h` |
| EncLib | `source/Lib/EncoderLib/EncLib.h` |
| EncCfg | `source/Lib/EncoderLib/EncCfg.h` |
| EncGOP | `source/Lib/EncoderLib/EncGOP.h` |
| EncPicture | `source/Lib/EncoderLib/EncPicture.h` |
| EncSlice | `source/Lib/EncoderLib/EncSlice.h` |
| EncCu | `source/Lib/EncoderLib/EncCu.h` |
| EncModeCtrl | `source/Lib/EncoderLib/EncModeCtrl.h` |
| IntraSearch | `source/Lib/EncoderLib/IntraSearch.h` |
| InterSearch | `source/Lib/EncoderLib/InterSearch.h` |
| RateCtrl | `source/Lib/EncoderLib/RateCtrl.h` |
| PreProcess | `source/Lib/EncoderLib/PreProcess.h` |
| CABACWriter | `source/Lib/EncoderLib/CABACWriter.h` |
| Picture | `source/Lib/CommonLib/Picture.h` |
| CodingStructure | `source/Lib/CommonLib/CodingStructure.h` |
| IntraPrediction | `source/Lib/CommonLib/IntraPrediction.h` |
| InterPrediction | `source/Lib/CommonLib/InterPrediction.h` |
| TrQuant | `source/Lib/CommonLib/TrQuant.h` |
| LoopFilter | `source/Lib/CommonLib/LoopFilter.h` |
| AdaptiveLoopFilter | `source/Lib/CommonLib/AdaptiveLoopFilter.h` |
| SampleAdaptiveOffset | `source/Lib/CommonLib/SampleAdaptiveOffset.h` |
| MCTF | `source/Lib/CommonLib/MCTF.h` |
| RdCost | `source/Lib/CommonLib/RdCost.h` |
| OutputBitstream | `source/Lib/CommonLib/BitStream.h` |
