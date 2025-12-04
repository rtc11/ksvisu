module ksvisu::color;

import std::math::random;

const String RESET_COLOR = "\x1b[0m";
const String ANSI_FG = "\x1b[38;2;%d;%d;%d;m%s%s";
const String ANSI_BG = "\x1b[48;2;%d;%d;%d;m%s%s";
const String ANSI_FG_CHAR = "\x1b[38;2;%d;%d;%d;m%c%s";

alias Color = int[3];
const Color RED =    {180, 50, 70  }; // #B43246
const Color GREEN =  {120, 240, 120}; // #78f078
const Color PINK =   {255, 105, 180}; // #FF69B4
const Color BLUE =   {70, 130, 200 }; // #4682C8
const Color CYAN =   {69, 133, 136 }; // #458588
const Color PURPLE = {120,  60, 180}; // #783CB4
const Color GRAY =   {128, 128, 128}; // #808080
const Color GOLD =   {200, 280, 60 }; // #C8B43C
const Color BLACK =  {0, 0, 0 }; // #000000

fn String String.fg(&self, Color color) => string::tformat(ANSI_FG, color[0], color[1], color[2], *self, color::RESET_COLOR);
fn String String.bg(&self, Color color) => string::tformat(ANSI_BG, color[0], color[1], color[2], *self, color::RESET_COLOR);

fn String random(String str) => string::tformat(ANSI_FG, rand(150)+50, rand(150)+50, rand(150)+50, str, RESET_COLOR);
fn String green(String str)  => str.fg(GREEN);  // #78f078
fn String cyan(String str)   => str.fg(CYAN);   // #458588
fn String blue(String str)   => str.fg(BLUE);   // #4682C8
fn String gold(String str)   => str.fg(GOLD);   // #C8B43C
fn String red(String str)    => str.fg(RED);    // #B43246
fn String pink(String str)   => str.fg(PINK);   // #FF69B4
fn String purple(String str) => str.fg(PURPLE); // #783CB4
fn String gray(String str)   => str.fg(GRAY);   // #808080

fn String rainbow(String str, int span = 1)
{
    DString out;
    Color c = {rand(150)+50, rand(150)+50, rand(150)+50};
    foreach(i, ch: str) {
        if (i % span == 0) {
            c = {rand(150)+50, rand(150)+50, rand(150)+50};
        }
        out.append(string::tformat(ANSI_FG_CHAR, c[0], c[1], c[2], ch, RESET_COLOR));
    }
    return out.str_view();
} 
