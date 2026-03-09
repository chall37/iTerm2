#!/bin/bash
# Compare the 8 standard ANSI colors with similar colors from the 256 color palette

# Reset
RESET="\033[0m"

# Function to print a color swatch using 256-color mode
print_256_color() {
    local num=$1
    printf "\033[48;5;${num}m    \033[0m"
}

# Function to print a color swatch using ANSI color
print_ansi_color() {
    local num=$1
    printf "\033[4${num}m    \033[0m"
}

echo "=============================================="
echo "  ANSI Colors vs 256 Color Palette Comparison"
echo "=============================================="
echo ""
echo "The 256-color palette includes:"
echo "  - Colors 0-7: Standard ANSI colors"
echo "  - Colors 8-15: Bright ANSI colors"
echo "  - Colors 16-231: 6x6x6 color cube"
echo "  - Colors 232-255: Grayscale ramp"
echo ""
echo "Below we compare each ANSI color (0-7) with similar"
echo "colors from the 6x6x6 cube (colors 16-231)."
echo ""

# ANSI color names
declare -a NAMES=("Black" "Red" "Green" "Yellow" "Blue" "Magenta" "Cyan" "White")

# Similar colors from the 216-color cube for each ANSI color
# Format: ANSI_NUM -> array of similar 256-palette colors
declare -a BLACK_SIMILAR=(16 232 233 234 235)
declare -a RED_SIMILAR=(124 160 196 88 52)
declare -a GREEN_SIMILAR=(28 34 40 22 70)
declare -a YELLOW_SIMILAR=(178 184 220 214 208)
declare -a BLUE_SIMILAR=(19 20 21 27 33)
declare -a MAGENTA_SIMILAR=(127 128 129 163 164)
declare -a CYAN_SIMILAR=(30 31 37 43 44)
declare -a WHITE_SIMILAR=(188 249 250 251 252)

echo "Legend: [ANSI color] followed by similar colors from 256-palette"
echo ""

for i in {0..7}; do
    printf "%-8s ANSI %d: " "${NAMES[$i]}" "$i"
    print_ansi_color $i
    printf "  vs 256-palette: "

    # Get the similar colors array for this ANSI color
    case $i in
        0) similar=("${BLACK_SIMILAR[@]}") ;;
        1) similar=("${RED_SIMILAR[@]}") ;;
        2) similar=("${GREEN_SIMILAR[@]}") ;;
        3) similar=("${YELLOW_SIMILAR[@]}") ;;
        4) similar=("${BLUE_SIMILAR[@]}") ;;
        5) similar=("${MAGENTA_SIMILAR[@]}") ;;
        6) similar=("${CYAN_SIMILAR[@]}") ;;
        7) similar=("${WHITE_SIMILAR[@]}") ;;
    esac

    for color in "${similar[@]}"; do
        print_256_color $color
        printf " %3d " "$color"
    done
    echo ""
done

echo ""
echo "=============================================="
echo "  Side-by-side: ANSI 0-7 vs 256-palette 0-7"
echo "=============================================="
echo ""
echo "Note: In the 256-color palette, colors 0-7 ARE the ANSI colors."
echo "They should appear identical:"
echo ""

printf "ANSI mode:      "
for i in {0..7}; do
    print_ansi_color $i
done
echo ""

printf "256-color 0-7:  "
for i in {0..7}; do
    print_256_color $i
done
echo ""

echo ""
echo "=============================================="
echo "  Full 6x6x6 Color Cube (colors 16-231)"
echo "=============================================="
echo ""
echo "The cube uses RGB values where each component is 0-5."
echo "Color number = 16 + 36*r + 6*g + b"
echo ""

for r in {0..5}; do
    printf "R=%d: " "$r"
    for g in {0..5}; do
        for b in {0..5}; do
            color=$((16 + 36*r + 6*g + b))
            print_256_color $color
        done
        printf " "
    done
    echo ""
done

echo ""
echo "=============================================="
echo "  Grayscale Ramp (colors 232-255)"
echo "=============================================="
echo ""

printf "232-243: "
for i in {232..243}; do
    print_256_color $i
done
echo ""

printf "244-255: "
for i in {244..255}; do
    print_256_color $i
done
echo ""

echo ""
echo "=============================================="
echo "  Bright ANSI Colors (8-15) vs 256-palette"
echo "=============================================="
echo ""

declare -a BRIGHT_NAMES=("Bright Black" "Bright Red" "Bright Green" "Bright Yellow" "Bright Blue" "Bright Magenta" "Bright Cyan" "Bright White")

for i in {0..7}; do
    bright=$((i + 8))
    printf "%-14s ANSI 1;3%d: " "${BRIGHT_NAMES[$i]}" "$i"
    # Bright ANSI colors using bold + color
    printf "\033[1;4${i}m    \033[0m"
    printf "  vs 256-color %2d: " "$bright"
    print_256_color $bright
    echo ""
done

echo ""
