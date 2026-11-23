%option noyywrap yylineno noinput nounput never-interactive

%{
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "parser.tab.h"

/* Before each rule action, save the token's source line for Bison. */
#define YY_USER_ACTION yylloc.first_line = yylloc.last_line = yylineno;
%}

DIGIT   [0-9]
NUMBER  ({DIGIT}+(\.{DIGIT}*)?|\.{DIGIT}+)
NAME    [A-Za-z_][A-Za-z_0-9]*

%%
    /* Keywords come before the NAME rule so they win equal-length matches. */
"START"       { return START; }
"END"         { return END; }
"let"         { return LET; }
"print"       { return PRINT; }
"read"        { return READ; }
"if"          { return IF; }
"else"        { return ELSE; }
"symbols"     { return SYMBOLS; }

"discount"    { return DISCOUNT; }
"tax"         { return TAX; }
"interest"    { return INTEREST; }
"savings"     { return SAVINGS; }
"emi"         { return EMI; }
"max"         { return MAX; }
"min"         { return MIN; }
"avg"         { return AVG; }
"sqrt"        { return SQRT; }
"pow"         { return POW; }

">="          { return GE; }
"<="          { return LE; }
"=="          { return EQ; }
"!="          { return NE; }
[-+*/%(){};,=<>] { return yytext[0]; }

{NUMBER}      {
                  yylval.number = strtod(yytext, NULL);
                  if (!isfinite(yylval.number))
                      return NUMBER_TOO_LARGE;
                  return NUM;
              }
{NAME}        {
                  if ((size_t)yyleng >= sizeof(yylval.name))
                      return NAME_TOO_LONG;
                  strcpy(yylval.name, yytext);
                  return ID;
              }
[ \t\r\n]+    { /* Skip whitespace without returning a token. */ }
.             { return INVALID; } /* Bison reports the invalid character. */

%%
