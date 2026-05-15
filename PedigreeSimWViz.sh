#!/bin/bash
set -euo pipefail

# Функция для отображения справки
usage() {
    cat << EOF
Использование: $0 [ОПЦИИ]

ОБЯЗАТЕЛЬНЫЕ ПАРАМЕТРЫ:
    --mother-vcf FILE      VCF файл матери (сжатый bgzip)
    --father-vcf FILE      VCF файл отца (сжатый bgzip)
    --beagle-jar FILE      Путь к beagle.jar
    --beagle-map FILE      Генетическая карта для Beagle (формат .map)
    --genetic-map FILE     Генетическая карта для ped-sim (формат simmap)
    --ped-sim FILE         Путь к исполняемому файлу ped-sim

ОПЦИОНАЛЬНЫЕ ПАРАМЕТРЫ:
    --output-dir DIR       Директория для результатов (по умолчанию: simulation_output)
    --num-children NUM     Количество симулируемых детей (по умолчанию: 100)
    --seed NUM             Seed для воспроизводимости (по умолчанию: 42)
    --threads NUM          Количество потоков для Beagle (по умолчанию: 6)
    --java-mem MEM         Память для Java (по умолчанию: 14g)
    --chromosomes LIST     Список хромосом через запятую (по умолчанию: 1-22)
    --keep-intermediate    Сохранять промежуточные файлы
    --viz                  Запустить визуализацию peddy и сжатие VCF
    -h, --help             Показать эту справку

Пример:
    $0 \\
        --mother-vcf /path/to/HG007.vcf.gz \\
        --father-vcf /path/to/HG006.vcf.gz \\
        --beagle-jar /path/to/beagle.jar \\
        --beagle-map /path/to/beagle_map.map \\
        --genetic-map /path/to/genetic_map.simmap \\
        --ped-sim /path/to/ped-sim \\
        --output-dir results/simulation \\
        --viz
EOF
    exit 0
}

# Значения по умолчанию
OUTPUT_DIR="simulation_output"
NUM_CHILDREN=100
SEED=42
THREADS=6
JAVA_MEM="14g"
CHROMOSOMES="1-22"
KEEP_INTERMEDIATE=false
RUN_VIZ=false

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
    case $1 in
        --mother-vcf)
            MOTHER_VCF="$2"
            shift 2
            ;;
        --father-vcf)
            FATHER_VCF="$2"
            shift 2
            ;;
        --beagle-jar)
            BEAGLE_JAR="$2"
            shift 2
            ;;
        --beagle-map)
            BEAGLE_MAP="$2"
            shift 2
            ;;
        --genetic-map)
            GENETIC_MAP="$2"
            shift 2
            ;;
        --ped-sim)
            PEDSIM="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --num-children)
            NUM_CHILDREN="$2"
            shift 2
            ;;
        --seed)
            SEED="$2"
            shift 2
            ;;
        --threads)
            THREADS="$2"
            shift 2
            ;;
        --java-mem)
            JAVA_MEM="$2"
            shift 2
            ;;
        --chromosomes)
            CHROMOSOMES="$2"
            shift 2
            ;;
        --keep-intermediate)
            KEEP_INTERMEDIATE=true
            shift
            ;;
        --viz)
            RUN_VIZ=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "❌ Неизвестный параметр: $1"
            usage
            ;;
    esac
done

# Проверка обязательных параметров
check_required() {
    local var_name="$1"
    local var_value="${!var_name:-}"
    if [ -z "$var_value" ]; then
        echo "❌ Ошибка: параметр ${var_name} обязателен"
        usage
    fi
    if [ ! -f "$var_value" ] && [ "$var_name" != "PEDSIM" ]; then
        echo "❌ Файл не найден: $var_value"
        exit 1
    fi
}

check_required "MOTHER_VCF"
check_required "FATHER_VCF"
check_required "BEAGLE_JAR"
check_required "BEAGLE_MAP"
check_required "GENETIC_MAP"
check_required "PEDSIM"

if [ ! -f "$PEDSIM" ] && [ ! -x "$PEDSIM" ]; then
    echo "❌ ped-sim не найден или не исполняемый: $PEDSIM"
    if command -v ped-sim &> /dev/null; then
        PEDSIM=$(command -v ped-sim)
        echo "✅ Найден в PATH: $PEDSIM"
    else
        echo "Поиск ped-sim в системе..."
        find / -name "ped-sim" -type f 2>/dev/null | head -5
        exit 1
    fi
fi

chmod +x "$PEDSIM" 2>/dev/null || true

# Преобразование строки хромосом в массив
if [[ "$CHROMOSOMES" == *-* ]]; then
    IFS='-' read -r start_chr end_chr <<< "$CHROMOSOMES"
    CHR_ARRAY=($(seq "$start_chr" "$end_chr"))
else
    IFS=',' read -ra CHR_ARRAY <<< "$CHROMOSOMES"
fi

echo "============================================"
echo "=== Симуляция генетических данных ==="
echo "============================================"
echo "Выходная директория: $OUTPUT_DIR"
echo "Мать: $MOTHER_VCF"
echo "Отец: $FATHER_VCF"
echo "Beagle JAR: $BEAGLE_JAR"
echo "Beagle карта: $BEAGLE_MAP"
echo "Генетическая карта (ped-sim): $GENETIC_MAP"
echo "ped-sim: $PEDSIM"
echo "Количество детей: $NUM_CHILDREN"
echo "Хромосомы: ${CHR_ARRAY[*]}"
echo "Seed: $SEED"
echo "Визуализация peddy: $RUN_VIZ"
echo "============================================"

START_TOTAL=$(date +%s)

# Создание выходной директории
mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

# 1. Фильтрация biallelic SNPs
echo -e "\n=== [1/4] Фильтрация biallelic SNPs ==="
echo "Обработка материнского VCF..."
bcftools view -m2 -M2 -v snps -Oz -o mother_b.vcf.gz "$MOTHER_VCF"
bcftools index --tbi mother_b.vcf.gz

echo "Обработка отцовского VCF..."
bcftools view -m2 -M2 -v snps -Oz -o father_b.vcf.gz "$FATHER_VCF"
bcftools index --tbi father_b.vcf.gz

echo "Объединение родительских VCF..."
bcftools merge --force-samples mother_b.vcf.gz father_b.vcf.gz -Oz -o parents_merged.vcf.gz
bcftools index --tbi parents_merged.vcf.gz

# 2. Phasing через Beagle
echo -e "\n=== [2/4] Фазирование (Beagle) ==="

for chr in "${CHR_ARRAY[@]}"; do
    echo "--- Фазирование хромосомы ${chr} ---"
    
    bcftools view --regions "chr${chr}" -Oz -o "parents_chr${chr}.vcf.gz" parents_merged.vcf.gz
    bcftools index "parents_chr${chr}.vcf.gz"
    
    java -Xmx"$JAVA_MEM" -jar "$BEAGLE_JAR" \
        gt="parents_chr${chr}.vcf.gz" \
        map="$BEAGLE_MAP" \
        out="phased_chr${chr}" \
        nthreads="$THREADS" \
        impute=false \
        window=20 \
        overlap=4 \
        burnin=3 \
        iterations=10
    
    bcftools index --tbi "phased_chr${chr}.vcf.gz"
    
    if [ "$KEEP_INTERMEDIATE" = false ]; then
        rm -f "parents_chr${chr}.vcf.gz" "parents_chr${chr}.vcf.gz.tbi"
    fi
done

echo "Объединение фазированных хромосом..."
PHASED_FILES=()
for chr in "${CHR_ARRAY[@]}"; do
    PHASED_FILES+=("phased_chr${chr}.vcf.gz")
done
bcftools concat -a "${PHASED_FILES[@]}" -Oz -o parents_phased.vcf.gz
bcftools index --tbi parents_phased.vcf.gz

# 3. Симуляция с ped-sim
echo -e "\n=== [3/4] Симуляция потомства ==="

echo "Подготовка генетической карты для ped-sim..."
awk -v OFS="\t" '
    NR==1 { print; next }
    {
        chrom = $1
        if (chrom ~ /^[0-9]+$/) chrom = "chr" chrom
        if (chrom ~ /^chrchr/) gsub(/^chrchr/, "chr", chrom)
        if (chrom ~ /^(chr)?[0-9]+$/ || chrom ~ /^(chr)?[XY]$/) {
            $1 = chrom
            print
        }
    }
' "$GENETIC_MAP" > map_1-22.map

echo "Первые 10 строк карты ped-sim:"
head -n 10 map_1-22.map
echo "Хромосомы в карте:"
cut -f1 map_1-22.map | sort -u

cat > family.def << EOF
def F1 1 2 F
2 $NUM_CHILDREN
EOF

echo "Запуск ped-sim (${NUM_CHILDREN} детей)..."

# Если включена визуализация, добавляем --fam для создания .fam файла
PEDSIM_EXTRA_ARGS=""
if [ "$RUN_VIZ" = true ]; then
    PEDSIM_EXTRA_ARGS="--fam"
    echo "  + флаг --fam для создания .fam файла"
fi

"$PEDSIM" \
    -d family.def \
    -m map_1-22.map \
    -i parents_phased.vcf.gz \
    -o children_1-22 \
    --pois \
    --keep_phase \
    --fam \
    --seed "$SEED" \
    --n "$NUM_CHILDREN" \
    $PEDSIM_EXTRA_ARGS

echo "ped-sim завершён успешно"

# 4. Анализ результатов
echo -e "\n=== [4/5] Анализ кроссоверов ==="
python3 - << PYEND
import pandas as pd
import glob
import os

seg_files = sorted(glob.glob("children_1-22*.seg"))
print(f"Найдено .seg файлов: {len(seg_files)}")

if not seg_files:
    seg_files = sorted(glob.glob("*.seg"))
    print(f"Альтернативный поиск: {len(seg_files)} файлов")
    
if not seg_files:
    print("❌ .seg файлы не найдены!")
    os.system("ls -la")
    exit(1)

print(f"Первые 3 файла: {seg_files[:3]}")

with open(seg_files[0], 'r') as f:
    lines = [f.readline().strip() for _ in range(5)]
print("Первые строки первого файла:")
for line in lines:
    print(f"  {line}")

all_data = []
for seg_file in seg_files:
    try:
        df = pd.read_csv(seg_file, sep="\t", comment="#", header=None)
        base = os.path.basename(seg_file)
        
        if 'children_1-22' in base:
            parts = base.replace('children_1-22', '').replace('.seg', '').strip('_')
            child_id = parts if parts else 'unknown'
        else:
            child_id = base.replace('.seg', '')
        
        if df.shape[1] >= 9:
            df.columns = ['s1', 's2', 'chr', 'start', 'end', 'type', 'gstart', 'gend', 'cM']
        elif df.shape[1] == 6:
            df.columns = ['s1', 's2', 'chr', 'start', 'end', 'type']
        else:
            print(f"⚠️ Неизвестный формат в {seg_file}: {df.shape[1]} колонок")
            continue
        
        df['child'] = child_id
        all_data.append(df)
        
    except Exception as e:
        print(f"⚠️ Ошибка чтения {seg_file}: {e}")
        continue

if not all_data:
    print("❌ Не удалось прочитать ни один .seg файл")
    exit(1)

combined = pd.concat(all_data, ignore_index=True)
print(f"\nВсего записей: {len(combined)}")
print(f"Уникальных детей: {combined['child'].nunique()}")

if 's1' in combined.columns and 's2' in combined.columns:
    stats = (combined.groupby(['child', 's1', 's2']).size()
             .reset_index(name='segments'))
    child_stats = (stats.groupby('child')['segments']
                   .sum()
                   .reset_index()
                   .assign(crossovers=lambda x: x['segments'] - 1))
else:
    child_stats = (combined.groupby('child').size()
                   .reset_index(name='segments')
                   .assign(crossovers=lambda x: x['segments'] - 1))

print("\n=== СТАТИСТИКА КРОССОВЕРОВ ===")
print(f"Количество проанализированных детей: {len(child_stats)}")

if len(child_stats) > 0:
    stats_desc = child_stats['crossovers'].describe()
    print(f"  Среднее: {stats_desc['mean']:.2f}")
    print(f"  Медиана: {stats_desc['50%']:.2f}")
    print(f"  Стд.откл: {stats_desc['std']:.2f}")
    print(f"  Минимум: {stats_desc['min']:.0f}")
    print(f"  Максимум: {stats_desc['max']:.0f}")
    print(f"  25% квартиль: {stats_desc['25%']:.2f}")
    print(f"  75% квартиль: {stats_desc['75%']:.2f}")
    
    child_stats.to_csv("crossovers_summary_1-22.csv", index=False)
    print(f"\n✅ Статистика сохранена: crossovers_summary_1-22.csv")
    print(f"   Всего детей: {len(child_stats)}")
    
    print("\nРаспределение кроссоверов по детям:")
    dist = child_stats['crossovers'].value_counts().sort_index()
    for cross, count in dist.head(15).items():
        bar = '█' * (count // max(1, dist.max() // 20))
        print(f"  {int(cross):3d}: {int(count):4d} детей {bar}")
else:
    print("❌ Не удалось построить статистику")
PYEND

# 5. Визуализация (опционально)
if [ "$RUN_VIZ" = true ]; then
    echo -e "\n=== [5/5] Визуализация peddy ==="
    
    if [ ! -f "children_1-22.vcf" ]; then
        echo "⚠️ VCF файл children_1-22.vcf не найден!"
        ls -la children_1-22* 2>/dev/null || echo "Файлы не найдены"
    else
        echo "Сжатие VCF файла..."
        bgzip children_1-22.vcf
        bcftools index -f --tbi children_1-22.vcf.gz
        
        # .fam файл уже создан ped-sim с флагом --fam
        if [ ! -f "children_1-22-everyone.fam" ]; then
            echo "❌ .fam файл не найден! ped-sim должен был создать его с флагом --fam"
            echo "Проверьте вывод ped-sim на наличие ошибок"
            exit 1
        fi
        
        echo "Запуск peddy..."
        python -m peddy --plot --sites hg38 children_1-22.vcf.gz children_1-22-everyone.fam
        
        echo "✅ Визуализация peddy завершена"
    fi
else
    echo -e "\n=== [5/5] Визуализация пропущена (используйте --viz для включения) ==="
fi

# Очистка
if [ "$KEEP_INTERMEDIATE" = false ]; then
    echo -e "\nОчистка промежуточных файлов..."
    rm -f mother_b.vcf.gz* father_b.vcf.gz* parents_merged.vcf.gz*
    rm -f phased_chr*.vcf.gz* parents_chr*.vcf.gz*
fi

# Итоги
TOTAL_TIME=$(( $(date +%s) - START_TOTAL ))
echo -e "\n============================================"
echo "🎉 Симуляция успешно завершена!"
echo "============================================"
echo "Результаты в: $(pwd)"
echo "Выходной VCF: children_1-22.vcf.gz"
echo "Статистика: crossovers_summary_1-22.csv"
if [ "$RUN_VIZ" = true ]; then
    echo "Peddy отчёты: children_1-22*.html"
fi
echo "Общее время: ${TOTAL_TIME} сек ($(( TOTAL_TIME / 60 )) мин $(( TOTAL_TIME % 60 )) сек)"
echo "============================================"
