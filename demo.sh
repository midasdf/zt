#!/bin/bash
# zt v0.5.10 feature demo

clear

# Title
printf '\e[1;36m  ⚡zt v0.5.10 — Feature Demo\e[0m\n'
printf '\e[2m  the fastest terminal emulator. pure zig.\e[0m\n'
echo ""

# SGR attributes
printf '  \e[1mBold\e[0m  \e[2mDim\e[0m  \e[3mItalic\e[0m  \e[7mReverse\e[0m  \e[9mStrike\e[0m\n'
echo ""

# Styled underlines
printf '  \e[4:1mSingle\e[0m  \e[4:2mDouble\e[0m  \e[4:3mCurly\e[0m  \e[4:4mDotted\e[0m  \e[4:5mDashed\e[0m\n'
echo ""

# Underline colors
printf '  \e[4:3m\e[58;2;255;80;80mError\e[0m  '
printf '\e[4:3m\e[58;2;255;200;50mWarning\e[0m  '
printf '\e[4:3m\e[58;2;80;200;120mHint\e[0m  '
printf '\e[4:1m\e[58;2;100;150;255mInfo\e[0m\n'
echo ""

# TrueColor gradient
printf '  '
for i in $(seq 0 39); do
  r=$(( 255 - i * 6 ))
  g=$(( i * 6 ))
  b=$(( 128 + i * 3 ))
  printf "\e[48;2;%d;%d;%dm " "$r" "$g" "$b"
done
printf '\e[0m\n'
printf '  '
for i in $(seq 0 39); do
  r=$(( i * 6 ))
  g=$(( 128 + i * 3 ))
  b=$(( 255 - i * 6 ))
  printf "\e[48;2;%d;%d;%dm " "$r" "$g" "$b"
done
printf '\e[0m\n'
echo ""

# 256 colors (first 16)
printf '  '
for i in $(seq 0 15); do
  printf "\e[48;5;%dm  " "$i"
done
printf '\e[0m\n'
echo ""

# Hyperlinks
printf '  \e]8;;https://github.com/midasdf/zt\e\\github.com/midasdf/zt\e]8;;\e\\\n'
echo ""

# Box drawing
printf '  \e[36m┌────────────────────────────────┐\e[0m\n'
printf '  \e[36m│\e[0m  Fastest throughput & startup  \e[36m│\e[0m\n'
printf '  \e[36m│\e[0m  Lowest memory footprint       \e[36m│\e[0m\n'
printf '  \e[36m└────────────────────────────────┘\e[0m\n'
echo ""

# Nerd font icons
printf '  \e[33m\e[0m Zig  \e[34m\e[0m Term  \e[32m\e[0m Git  \e[31m\e[0m Fast  '
printf '\e[35m\e[0m Code  \e[36m\e[0m SSH  \e[33m\e[0m Dir\n'
echo ""

printf '\e[2m  OSC 52 clipboard ✓  Styled underlines ✓  OSC 8 hyperlinks ✓\e[0m\n'
