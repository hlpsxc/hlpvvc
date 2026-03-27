#!/usr/bin/env bash
set -euo pipefail

# ============================================
# VVenC Benchmark Script for macOS
# Target: 720p30, preset=faster
# 支持任意封装格式输入，自动用 ffmpeg 转 YUV
# ============================================

# ---------- 用户可修改区 ----------
VVENC_BIN="${VVENC_BIN:-./bin/release-static/vvencapp}"
FFMPEG_BIN="${FFMPEG_BIN:-./ffmpeg}"

# 压测参数
WIDTH="${WIDTH:-720}"
HEIGHT="${HEIGHT:-1080}"
FPS="${FPS:-30}"
CLIP_SECONDS="${CLIP_SECONDS:-30}"
BITDEPTH="${BITDEPTH:-8}"
CHROMA="${CHROMA:-420}"
PRESET="${PRESET:-faster}"
OUTPUT_DIR="${OUTPUT_DIR:-./vvenc_bench_out}"
CSV_FILE="${CSV_FILE:-$OUTPUT_DIR/results.csv}"

# 扫描参数
THREADS_LIST=(${THREADS_LIST:-4 6 8 12})
QP_LIST=(${QP_LIST:-34 32 30})
QPA_LIST=(${QPA_LIST:-0 1})

# ---------- 结束用户可修改区 ----------

# ────────────────────────────────────────────
# 0. 参数解析
# ────────────────────────────────────────────
usage() {
  echo "用法：$0 <input_file> [clip_seconds]"
  echo ""
  echo "  input_file    任意封装格式（mp4/mkv/mov/flv/yuv 等）"
  echo "  clip_seconds  截取秒数，默认 30"
  echo ""
  echo "示例："
  echo "  $0 input.mp4"
  echo "  $0 input.mp4 60"
  echo "  WIDTH=1920 HEIGHT=1080 $0 input.mp4"
  exit 1
}

if [[ $# -lt 1 ]]; then
  usage
fi

SOURCE_FILE="$1"
CLIP_SECONDS="${2:-$CLIP_SECONDS}"

# ────────────────────────────────────────────
# 1. 依赖 & 输入检查
# ────────────────────────────────────────────
check_dep() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: '$1' not found. $2"
    exit 1
  fi
}

check_dep "$VVENC_BIN"  "请先编译 vvencapp，或用 VVENC_BIN=/path/to/vvencapp 指定路径"
check_dep "$FFMPEG_BIN" "请将 ffmpeg 放到当前目录，或用 FFMPEG_BIN=/path/to/ffmpeg 指定路径"
check_dep python3       "请安装 python3"

if [[ ! -f "$SOURCE_FILE" ]]; then
  echo "ERROR: 输入文件不存在: $SOURCE_FILE"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

# ────────────────────────────────────────────
# 2. 工具函数
# ────────────────────────────────────────────
calc_float() {
  python3 -c "print($1)"
}

now_ts() {
  python3 -c "import time; print(f'{time.time():.6f}')"
}

# ────────────────────────────────────────────
# 3. 确定实际帧数
# ────────────────────────────────────────────
FRAMES=$(python3 -c "print(int(${CLIP_SECONDS} * ${FPS}))")

# ────────────────────────────────────────────
# 4. ffmpeg 转换
# ────────────────────────────────────────────
YUV_FILE="$OUTPUT_DIR/input_${WIDTH}x${HEIGHT}_${FPS}_${CLIP_SECONDS}s.yuv"

ext="${SOURCE_FILE##*.}"
ext_lower=$(echo "$ext" | tr "[:upper:]" "[:lower:]")
if [[ "$ext_lower" == "yuv" ]]; then
  echo ">>> 输入已是 YUV 文件，跳过 ffmpeg 转换"
  YUV_FILE="$SOURCE_FILE"
else
  if [[ -f "$YUV_FILE" ]]; then
    echo ">>> YUV 缓存已存在，跳过 ffmpeg 转换：$YUV_FILE"
  else
    echo ">>> 使用 ffmpeg 转换前 ${CLIP_SECONDS}s → $YUV_FILE"

    if [[ "$BITDEPTH" == "10" ]]; then
      PIX_FMT="yuv${CHROMA}p10le"
    else
      PIX_FMT="yuv${CHROMA}p"
    fi

    "$FFMPEG_BIN" -y \
      -t "$CLIP_SECONDS" \
      -i "$SOURCE_FILE" \
      -vf "scale=${WIDTH}:${HEIGHT}:flags=lanczos,fps=${FPS}" \
      -pix_fmt "$PIX_FMT" \
      -an \
      "$YUV_FILE"

    echo ">>> 转换完成：$YUV_FILE"
  fi
fi

# 校验 YUV 文件大小是否合理
yuv_size=$(python3 -c "import os; print(os.path.getsize('$YUV_FILE'))")
expected_size=$(python3 -c "
w, h, frames, depth = $WIDTH, $HEIGHT, $FRAMES, $BITDEPTH
bytes_per_pixel = 2 if depth == 10 else 1
frame_size = w * h * 3 // 2 * bytes_per_pixel  # yuv420
print(frame_size * frames)
")
echo ">>> YUV 文件大小：${yuv_size} bytes（预期约 ${expected_size} bytes）"
if [[ "$yuv_size" -lt "$expected_size" ]]; then
  echo "WARNING: YUV 文件比预期小，实际可用帧数可能不足 ${FRAMES} 帧"
  FRAMES=$(python3 -c "
w, h, depth = $WIDTH, $HEIGHT, $BITDEPTH
bytes_per_pixel = 2 if depth == 10 else 1
frame_size = w * h * 3 // 2 * bytes_per_pixel
print(max(1, $yuv_size // frame_size))
")
  echo ">>> 自动调整 FRAMES → $FRAMES"
fi

# ────────────────────────────────────────────
# 5. 写 CSV 表头
# ────────────────────────────────────────────
echo "preset,threads,qp,qpa,frames,elapsed_sec,encode_fps,rt_factor,realtime,output_bitstream" \
  > "$CSV_FILE"

echo "============================================================"
echo "VVenC Benchmark on macOS"
echo "Source     : $SOURCE_FILE"
echo "YUV input  : $YUV_FILE"
echo "Resolution : ${WIDTH}x${HEIGHT}"
echo "FPS        : $FPS"
echo "Clip       : ${CLIP_SECONDS}s  (${FRAMES} frames)"
echo "Preset     : $PRESET"
echo "Output Dir : $OUTPUT_DIR"
echo "CSV        : $CSV_FILE"
echo "============================================================"
echo

# ────────────────────────────────────────────
# 6. 单次编码函数
# ────────────────────────────────────────────
run_case() {
  local threads="$1"
  local qp="$2"
  local qpa="$3"

  local tag="p_${PRESET}_t${threads}_qp${qp}_qpa${qpa}"
  local bitstream="$OUTPUT_DIR/${tag}.266"
  local logfile="$OUTPUT_DIR/${tag}.log"

  echo "------------------------------------------------------------"
  echo "Running: preset=$PRESET  threads=$threads  qp=$qp  qpa=$qpa"
  echo "------------------------------------------------------------"

  local start end elapsed fps_val rt_factor realtime rc=0

  start="$(now_ts)"

  # 编码，同时保留 stdout/stderr 到 log，失败不立即退出（捕获返回码）
  set +e
  "$VVENC_BIN" \
    -i "$YUV_FILE" \
    -s "${WIDTH}x${HEIGHT}" \
    --fps "$FPS" \
    --frames "$FRAMES" \
    --preset "$PRESET" \
    --threads "$threads" \
    --mtprofile auto \
    --qpa "$qpa" \
    -q "$qp" \
    --output "$bitstream" \
    >"$logfile" 2>&1
  rc=$?
  set -e

  end="$(now_ts)"

  # 编码失败：打印日志并跳过本轮
  if [[ $rc -ne 0 ]]; then
    echo "ERROR: vvencapp 返回码 $rc，日志如下："
    cat "$logfile"
    echo ">>> 跳过本组参数"
    echo
    return
  fi

  # 校验码流文件非空
  if [[ ! -s "$bitstream" ]]; then
    echo "ERROR: 码流文件为空：$bitstream，日志如下："
    cat "$logfile"
    echo ">>> 跳过本组参数"
    echo
    return
  fi

  elapsed="$(calc_float "${end} - ${start}")"
  fps_val="$(calc_float "${FRAMES} / ${elapsed}")"
  rt_factor="$(calc_float "${fps_val} / ${FPS}")"

  if python3 -c "import sys; sys.exit(0 if float('${rt_factor}') >= 1.0 else 1)"; then
    realtime="YES"
  else
    realtime="NO"
  fi

  printf "elapsed   : %.3f sec\n"  "$elapsed"
  printf "encode fps: %.3f\n"      "$fps_val"
  printf "rt factor : %.3f\n"      "$rt_factor"
  printf "realtime  : %s\n"        "$realtime"
  echo   "bitstream : $bitstream"
  echo

  echo "${PRESET},${threads},${qp},${qpa},${FRAMES},${elapsed},${fps_val},${rt_factor},${realtime},${bitstream}" \
    >> "$CSV_FILE"
}

# ────────────────────────────────────────────
# 7. 主循环
# ────────────────────────────────────────────
for t in "${THREADS_LIST[@]}"; do
  for qp in "${QP_LIST[@]}"; do
    for qpa in "${QPA_LIST[@]}"; do
      run_case "$t" "$qp" "$qpa"
    done
  done
done

# ────────────────────────────────────────────
# 8. 汇总输出
# ────────────────────────────────────────────
echo "============================================================"
echo "Benchmark finished."
echo "Results CSV: $CSV_FILE"
echo
echo "Top results (sorted by encode_fps):"
python3 - "$CSV_FILE" <<'PY'
import csv, sys
path = sys.argv[1]
rows = []
with open(path, newline='') as f:
    for row in csv.DictReader(f):
        try:
            row["encode_fps"] = float(row["encode_fps"])
            row["rt_factor"]  = float(row["rt_factor"])
            rows.append(row)
        except ValueError:
            pass

if not rows:
    print("没有成功的编码结果，请检查各组的 .log 文件")
    sys.exit(0)

rows.sort(key=lambda x: x["encode_fps"], reverse=True)
print(f"{'preset':8} {'thr':>4} {'qp':>4} {'qpa':>4} {'fps':>10} {'rt_factor':>10} {'rt':>8}")
for row in rows[:10]:
    print(f"{row['preset']:8} {row['threads']:>4} {row['qp']:>4} {row['qpa']:>4} "
          f"{row['encode_fps']:>10.3f} {row['rt_factor']:>10.3f} {row['realtime']:>8}")
PY
echo "============================================================"
