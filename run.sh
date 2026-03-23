#!/bin/bash
export OMP_NUM_THREADS=${OMP_NUM_THREADS:-120}
export OMP_PROC_BIND=${OMP_PROC_BIND:-spread}
export OMP_PLACES=${OMP_PLACES:-cores}

# Extract HPCG GFLOP/s metrics from run logs and save to CSV
extract_hpcg_metrics() {
    local csv_output="${OUT_RESULT_DIR}/hpcg_metrics.csv"

    echo "Run,GFLOPS" > "$csv_output"

    for i in 1 2 3 4 5; do
        local log_file="${OUT_RESULT_DIR}/log_${i}"
        if [ -f "$log_file" ]; then
            local gflops
            gflops=$(grep -E "GFLOP/s|GFLOPS" "$log_file" | grep -Eo "[0-9]+\.[0-9]+([eE][-+]?[0-9]+)?" | tail -1)
            gflops=${gflops:-N/A}

            echo "run_${i},${gflops}" >> "$csv_output"
            echo "[INFO] Run ${i}: GFLOPS=${gflops}"
        else
            echo "[WARN] Log file not found: $log_file"
        fi
    done

    echo "[INFO] HPCG metrics saved to: $csv_output"
    echo ""
    echo "========== HPCG Summary =========="
    column -t -s',' "$csv_output"
    echo "=================================="
}

# Extract HPCG GFLOP/s from ratio benchmark logs and generate plot (supports dual mode)
extract_ratio_hpcg_and_plot() {
    local output_dir="$1"
    local metrics_csv="${output_dir}/hpcg_ratio_results.csv"
    local plot_data="${output_dir}/hpcg_plot_data.dat"
    local plot_output="${output_dir}/hpcg_ratio_plot.png"

    echo "ratio,node0_weight,node1_weight,mode,run_index,gflops" > "$metrics_csv"

    for ratio_dir in "${output_dir}"/*/; do
        if [ -d "$ratio_dir" ]; then
            local dir_name
            dir_name=$(basename "$ratio_dir")
            [[ "$dir_name" != *"to"* ]] && continue

            local ratio
            ratio=$(echo "$dir_name" | sed 's/to/:/')
            local node0_weight="${ratio%%:*}"
            local node1_weight="${ratio##*:}"

            if [ -d "${ratio_dir}native" ] || [ -d "${ratio_dir}cxlmalloc" ]; then
                for mode in "native" "cxlmalloc"; do
                    local mode_dir="${ratio_dir}${mode}"
                    if [ -d "$mode_dir" ]; then
                        for log_file in "${mode_dir}/"log_*.log; do
                            if [ -f "$log_file" ]; then
                                local log_basename
                                log_basename=$(basename "$log_file" .log)
                                local run_index
                                run_index=$(echo "$log_basename" | sed 's/log_//')

                                local gflops
                                gflops=$(grep -E "GFLOP/s|GFLOPS" "$log_file" | grep -Eo "[0-9]+\.[0-9]+([eE][-+]?[0-9]+)?" | tail -1)
                                gflops=${gflops:-0}

                                echo "${ratio},${node0_weight},${node1_weight},${mode},${run_index},${gflops}" >> "$metrics_csv"
                            fi
                        done
                    fi
                done
            else
                for log_file in "${ratio_dir}"log_*.log; do
                    if [ -f "$log_file" ]; then
                        local log_basename
                        log_basename=$(basename "$log_file" .log)
                        local run_index
                        run_index=$(echo "$log_basename" | sed 's/log_//')

                        local gflops
                        gflops=$(grep -E "GFLOP/s|GFLOPS" "$log_file" | grep -Eo "[0-9]+\.[0-9]+([eE][-+]?[0-9]+)?" | tail -1)
                        gflops=${gflops:-0}

                        echo "${ratio},${node0_weight},${node1_weight},native,${run_index},${gflops}" >> "$metrics_csv"
                    fi
                done
            fi
        fi
    done

    echo "[INFO] HPCG ratio results saved to: $metrics_csv"

    echo "# ratio_label native_gflops cxlmalloc_gflops" > "$plot_data"
    awk -F, 'NR>1 {
        ratio=$1
        mode=$4
        gflops=$6
        key=ratio "_" mode
        sum[key] += gflops
        count[key]++
        ratios[ratio] = 1
    }
    END {
        n = asorti(ratios, sorted_ratios)
        for (i=1; i<=n; i++) {
            r = sorted_ratios[i]
            native_key = r "_native"
            cxl_key = r "_cxlmalloc"
            native_avg = (count[native_key] > 0) ? sum[native_key] / count[native_key] : 0
            cxl_avg = (count[cxl_key] > 0) ? sum[cxl_key] / count[cxl_key] : 0
            printf "%s %.6f %.6f\n", r, native_avg, cxl_avg
        }
    }' "$metrics_csv" >> "$plot_data"

    if command -v gnuplot >/dev/null 2>&1; then
        gnuplot <<-GNUPLOT_EOF
            set terminal pngcairo enhanced font 'Arial,12' size 1200,600
            set output '${plot_output}'
            set title 'HPCG GFLOPS vs Interleave Ratio'
            set xlabel 'Interleave Ratio (Node0:Node1)'
            set ylabel 'GFLOPS'
            set grid
            set style data linespoints
            set pointsize 1.5
            set xtics rotate by -45
            set key top right
            plot '${plot_data}' using 0:2:xtic(1) with linespoints pt 7 ps 1.5 lw 2 lc rgb '#0066cc' title 'Native', \
                 '${plot_data}' using 0:3:xtic(1) with linespoints pt 9 ps 1.5 lw 2 lc rgb '#cc3300' title 'CXLMalloc'
GNUPLOT_EOF
        echo "[INFO] Plot saved to: $plot_output"
    else
        python3 ${PCXL_ROOT}/benchmark/script/plot_fom_ratio.py "$plot_data" "$plot_output"
    fi

    echo ""
    echo "========== HPCG Ratio Summary =========="
    echo "Ratio        Native_GFLOPS  CXLMalloc_GFLOPS"
    awk 'NR>1 {printf "%-12s %-14s %s\n", $1, $2, $3}' "$plot_data"
    echo "========================================"
}

run_best_ratio_benchmark() {
    local output_dir="${1:-result/ratio_benchmark}"

    echo "[INFO] Running best ratio benchmark with both modes..."
    echo "[INFO] Output directory: $output_dir"

    find_best_ratio_with_modes "$output_dir" "$(realpath ./bin/xhpcg)" --nx=${HPCG_NX:-768} --ny=${HPCG_NY:-768} --nz=${HPCG_NZ:-768} --rt=${HPCG_RT:-45}

    echo "[INFO] Extracting HPCG metrics and generating plot..."
    extract_ratio_hpcg_and_plot "$output_dir"
}

extract_combine_hpcg_metrics() {
    local csv_output="${OUT_RESULT_DIR}/hpcg_combine_metrics.csv"

    echo "Run,NumaBalance,GFLOPS" > "$csv_output"

    for mode in "off" "on"; do
        local log_file="${OUT_RESULT_DIR}/log_numabalance_${mode}.log"
        if [ -f "$log_file" ]; then
            local gflops
            gflops=$(grep -E "GFLOP/s|GFLOPS" "$log_file" | grep -Eo "[0-9]+\.[0-9]+([eE][-+]?[0-9]+)?" | tail -1)
            gflops=${gflops:-N/A}

            echo "numabal_${mode},${mode},${gflops}" >> "$csv_output"
            echo "[INFO] NumaBalance ${mode}: GFLOPS=${gflops}"
        else
            echo "[WARN] Log file not found: $log_file"
        fi
    done

    echo "[INFO] HPCG combine metrics saved to: $csv_output"
    echo ""
    echo "========== HPCG Combine Summary =========="
    column -t -s',' "$csv_output"
    echo "=========================================="
}

# Estimate a near-1/3-memory working set for single-machine runs.
# You can override with HPCG_NX/HPCG_NY/HPCG_NZ or HPCG_BYTES_PER_POINT.
set_hpcg_problem_size_defaults() {
    if [ -n "${HPCG_NX}" ] && [ -n "${HPCG_NY}" ] && [ -n "${HPCG_NZ}" ]; then
        return
    fi

    local mem_kb
    mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)

    if [ -z "$mem_kb" ]; then
        HPCG_NX=${HPCG_NX:-768}
        HPCG_NY=${HPCG_NY:-768}
        HPCG_NZ=${HPCG_NZ:-768}
        return
    fi

    local bytes_per_point=${HPCG_BYTES_PER_POINT:-192}
    local target_bytes=$((mem_kb * 1024 / 3))
    local n
    n=$(awk -v t="$target_bytes" -v b="$bytes_per_point" 'BEGIN {
        x = exp(log(t / b) / 3.0)
        n = int(x / 16) * 16
        if (n < 192) n = 192
        print n
    }')

    HPCG_NX=${HPCG_NX:-$n}
    HPCG_NY=${HPCG_NY:-$n}
    HPCG_NZ=${HPCG_NZ:-$n}
}

print_hpcg_size_hint() {
    local bytes_per_point=${HPCG_BYTES_PER_POINT:-192}
    local approx_bytes
    approx_bytes=$(awk -v nx="$HPCG_NX" -v ny="$HPCG_NY" -v nz="$HPCG_NZ" -v b="$bytes_per_point" 'BEGIN {printf "%.0f", nx*ny*nz*b}')
    local approx_gib
    approx_gib=$(awk -v x="$approx_bytes" 'BEGIN {printf "%.2f", x/1024/1024/1024}')
    echo "[INFO] HPCG size: NX=${HPCG_NX}, NY=${HPCG_NY}, NZ=${HPCG_NZ}, RT=${HPCG_RT}s"
    echo "[INFO] Estimated footprint: ~${approx_gib} GiB (bytes/point=${bytes_per_point})"
}

REBUILD=$1
MODE=${2:-100000}

if [ "$MODE" == "ratio" ]; then
    source benchmark/script/run_common_best_ratio.sh
elif [ "$MODE" == "latency" ]; then
    source benchmark/script/run_measure_latency.sh
elif [ "$MODE" == "combine" ]; then
    source benchmark/script/run_combine.sh
elif [ "$MODE" == "vis_miss" ]; then
    source benchmark/script/run_measure_miss.sh
else
    source benchmark/script/run_common.sh
fi

pushd benchmark/hpcg
if [ "$REBUILD" -eq 1 ]; then
    echo "rebuilding...."
    HPCG_ARCH=${HPCG_ARCH:-GCC_OMP}
    if [ ! -f "setup/Make.${HPCG_ARCH}" ]; then
        echo "[ERROR] setup/Make.${HPCG_ARCH} not found"
        exit 1
    fi
    make clean || true
    make -j"$(nproc)" arch="${HPCG_ARCH}"
fi

if [ ! -x ./bin/xhpcg ]; then
    echo "[ERROR] benchmark/hpcg/bin/xhpcg not found or not executable"
    echo "[HINT] Run: HPCG_ARCH=GCC_OMP bash benchmark/hpcg/run.sh 1 111"
    exit 1
fi

set_hpcg_problem_size_defaults
HPCG_RT=${HPCG_RT:-45}
print_hpcg_size_hint

if [ "$MODE" == "ratio" ]; then
    OBJ_BANDWIDTH_RANK="${OUT_RESULT_DIR}/obj_bandwidth_rank.csv"
    export CXL_MALLOC_OBJ_RANK_RESULT="$(pwd)/${OBJ_BANDWIDTH_RANK}"
    RATIO_OUTPUT_DIR="${3:-result/ratio_benchmark}"
    run_best_ratio_benchmark "$RATIO_OUTPUT_DIR"
elif [ "$MODE" == "latency" ]; then
    run_and_measure_latency "$(realpath ./bin/xhpcg)" --nx=${HPCG_NX} --ny=${HPCG_NY} --nz=${HPCG_NZ} --rt=${HPCG_RT}
elif [ "$MODE" == "vis_miss" ]; then
    run_and_analyze_vis_miss "$(realpath ./bin/xhpcg)" --nx=${HPCG_NX} --ny=${HPCG_NY} --nz=${HPCG_NZ} --rt=${HPCG_RT}
elif [ "$MODE" == "combine" ]; then
    run_combine "$(realpath ./bin/xhpcg)" --nx=${HPCG_NX} --ny=${HPCG_NY} --nz=${HPCG_NZ} --rt=${HPCG_RT}

    echo "[INFO] Extracting HPCG metrics from combine log files..."
    extract_combine_hpcg_metrics
else
    run_and_analyze "$MODE" "$(realpath ./bin/xhpcg)" --nx=${HPCG_NX} --ny=${HPCG_NY} --nz=${HPCG_NZ} --rt=${HPCG_RT}

    echo "[INFO] Extracting HPCG metrics from log files..."
    extract_hpcg_metrics
fi

popd
