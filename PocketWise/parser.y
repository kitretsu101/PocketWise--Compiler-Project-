%{
#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#include <io.h>
#include <windows.h>
#else
#include <sys/stat.h>
#include <unistd.h>
#endif

#define MAX_VARIABLES 100

/* Entries at the same index belong to the same variable. */
static char names[MAX_VARIABLES][64];
static double values[MAX_VARIABLES];
static int variable_count = 0;

/* An inactive branch is parsed but its commands have no side effects. */
static int active = 1;
static FILE *results;

extern FILE *yyin;
extern int yylineno;
extern char *yytext;
int yylex(void);
void yyerror(const char *message);

static int find_variable(const char *name);
static int require_variable(const char *name, int line);
static int declare_variable(const char *name, double value, int line);
static int read_variable(const char *name, int line);
static void runtime_error(int line, const char *message);
static double monthly_payment(double principal, double annual_rate, double months);
static int save_results(const char *path);
%}

%locations

%union {
    double number;
    char name[64];
    int truth;
}

%token START END LET READ PRINT IF ELSE SYMBOLS
%token DISCOUNT TAX INTEREST SAVINGS EMI MAX MIN AVG SQRT POW
%token GE ">=" LE "<=" EQ "==" NE "!="
%token INVALID "invalid character"
%token NAME_TOO_LONG "identifier longer than 63 characters"
%token NUMBER_TOO_LARGE "number outside the supported range"
%token <number> NUM "number"
%token <name> ID "identifier"
%type <number> expr
%type <truth> condition

/* Precedence increases from top to bottom. */
%left '+' '-'
%left '*' '/' '%'

%%

program : START statements END ;

statements
    : /* empty */
    | statements command
    | statements if_statement
    ;

/* Blocks accept ordinary commands, keeping IF statements non-nested. */
block_commands
    : /* empty */
    | block_commands command
    ;

if_statement
    : IF '(' condition ')' { active = $3; }
      '{' block_commands '}' optional_else { active = 1; }
    ;

optional_else
    : /* empty */
    | ELSE { active = !active; } '{' block_commands '}'
    ;

condition
    : expr '>' expr { $$ = $1 > $3; }
    | expr '<' expr { $$ = $1 < $3; }
    | expr GE expr  { $$ = $1 >= $3; }
    | expr LE expr  { $$ = $1 <= $3; }
    | expr EQ expr  { $$ = $1 == $3; }
    | expr NE expr  { $$ = $1 != $3; }
    ;

command
    : LET ID '=' expr ';'
        {
            if (active && !declare_variable($2, $4, @2.first_line))
                YYABORT;
        }
    | ID '=' expr ';'
        {
            if (active) {
                int index = require_variable($1, @1.first_line);
                if (index < 0)
                    YYABORT;
                values[index] = $3;
            }
        }
    | READ ID ';'
        {
            if (active && !read_variable($2, @1.first_line))
                YYABORT;
        }
    | PRINT expr ';'
        {
            if (active)
                fprintf(results, "%.10g\n", $2);
        }
    | SYMBOLS ';'
        {
            if (active) {
                int i;
                fputs("Symbol table:\n", results);
                for (i = 0; i < variable_count; i++)
                    fprintf(results, "%s = %.10g\n", names[i], values[i]);
            }
        }
    ;

expr
    : NUM           { $$ = $1; }
    | ID
        {
            $$ = 0;
            if (active) {
                int index = require_variable($1, @1.first_line);
                if (index < 0)
                    YYABORT;
                $$ = values[index];
            }
        }
    | '(' expr ')' { $$ = $2; }
    /* With left associativity, unary minus reduces before the next product. */
    | '-' expr %prec '*' { $$ = -$2; }
    | expr '+' expr { $$ = $1 + $3; }
    | expr '-' expr { $$ = $1 - $3; }
    | expr '*' expr { $$ = $1 * $3; }
    | expr '/' expr
        {
            if (!active) {
                $$ = 0;
            } else if ($3 == 0) {
                runtime_error(@2.first_line, "division by zero");
                YYABORT;
            } else {
                $$ = $1 / $3;
            }
        }
    | expr '%' expr
        {
            if (!active) {
                $$ = 0;
            } else if ($3 == 0) {
                runtime_error(@2.first_line, "modulus by zero");
                YYABORT;
            } else {
                $$ = fmod($1, $3);
            }
        }
    | DISCOUNT '(' expr ',' expr ')'          { $$ = $3 * (1 - $5 / 100); }
    | TAX '(' expr ',' expr ')'               { $$ = $3 * ($5 / 100); }
    | INTEREST '(' expr ',' expr ',' expr ')' { $$ = $3 * ($5 / 100) * $7; }
    | SAVINGS '(' expr ',' expr ')'           { $$ = $3 - $5; }
    | MAX '(' expr ',' expr ')'               { $$ = $3 > $5 ? $3 : $5; }
    | MIN '(' expr ',' expr ')'               { $$ = $3 < $5 ? $3 : $5; }
    | AVG '(' expr ',' expr ')'               { $$ = $3 / 2 + $5 / 2; }
    | SQRT '(' expr ')'
        {
            $$ = 0;
            if (active) {
                if ($3 < 0) {
                    runtime_error(@1.first_line, "square root of a negative number");
                    YYABORT;
                }
                $$ = sqrt($3);
            }
        }
    | POW '(' expr ',' expr ')'
        {
            $$ = 0;
            if (active) {
                $$ = pow($3, $5);
                if (!isfinite($$)) {
                    runtime_error(@1.first_line, "invalid or out-of-range power");
                    YYABORT;
                }
            }
        }
    | EMI '(' expr ',' expr ',' expr ')'
        {
            $$ = 0;
            if (active) {
                if ($3 < 0 || $5 < 0 || $7 <= 0 || floor($7) != $7) {
                    runtime_error(@1.first_line,
                                  "emi needs a nonnegative principal and rate, and positive whole months");
                    YYABORT;
                }
                $$ = monthly_payment($3, $5, $7);
                if (!isfinite($$)) {
                    runtime_error(@1.first_line, "out-of-range EMI");
                    YYABORT;
                }
            }
        }
    ;

%%

static int find_variable(const char *name)
{
    int i;

    for (i = 0; i < variable_count; i++) {
        if (strcmp(names[i], name) == 0)
            return i;
    }
    return -1;
}

static int require_variable(const char *name, int line)
{
    int index = find_variable(name);

    if (index < 0)
        fprintf(stderr, "Line %d: undefined variable '%s'\n", line, name);
    return index;
}

static int declare_variable(const char *name, double value, int line)
{
    if (find_variable(name) >= 0) {
        fprintf(stderr, "Line %d: variable '%s' is already declared\n", line, name);
        return 0;
    }
    if (variable_count == MAX_VARIABLES) {
        runtime_error(line, "symbol table is full (100 variables)");
        return 0;
    }

    strcpy(names[variable_count], name);
    values[variable_count] = value;
    variable_count++;
    return 1;
}

static int read_variable(const char *name, int line)
{
    int index = require_variable(name, line);
    double input;
    int character;
    int valid;

    if (index < 0)
        return 0;
    if (yyin == stdin) {
        runtime_error(line, "run with a source filename to use read");
        return 0;
    }

    printf("Enter %s: ", name);
    fflush(stdout);
    valid = scanf("%lf", &input) == 1 && isfinite(input);

    /* Accept just one number per line, with optional trailing spaces. */
    while ((character = getchar()) != '\n' && character != EOF) {
        if (!isspace(character))
            valid = 0;
    }
    if (!valid) {
        runtime_error(line, "expected one finite number");
        return 0;
    }

    values[index] = input;
    return 1;
}

static double monthly_payment(double principal, double annual_rate, double months)
{
    double monthly_rate = annual_rate / 1200;

    if (monthly_rate == 0)
        return principal / months;

    /* Compute 1 - (1 + monthly_rate)^(-months) accurately for small rates. */
    return principal * (monthly_rate / -expm1(-months * log1p(monthly_rate)));
}

static void runtime_error(int line, const char *message)
{
    fprintf(stderr, "Line %d: %s\n", line, message);
}

void yyerror(const char *message)
{
    if (yychar == NAME_TOO_LONG)
        runtime_error(yylineno, "identifier longer than 63 characters");
    else if (yychar == NUMBER_TOO_LARGE)
        runtime_error(yylineno, "number outside the supported range");
    else if (yychar == 0)
        fprintf(stderr, "Line %d: %s at end of input\n", yylineno, message);
    else
        fprintf(stderr, "Line %d: %s near '%.32s'\n", yylineno, message, yytext);
}

/* Compare the open files so aliases cannot overwrite the source. */
static int same_file(FILE *first, FILE *second)
{
#ifdef _WIN32
    BY_HANDLE_FILE_INFORMATION a, b;
    if (!GetFileInformationByHandle((HANDLE)_get_osfhandle(_fileno(first)), &a) ||
        !GetFileInformationByHandle((HANDLE)_get_osfhandle(_fileno(second)), &b))
        return -1;
    return a.dwVolumeSerialNumber == b.dwVolumeSerialNumber &&
           a.nFileIndexHigh == b.nFileIndexHigh && a.nFileIndexLow == b.nFileIndexLow;
#else
    struct stat a, b;
    if (fstat(fileno(first), &a) != 0 || fstat(fileno(second), &b) != 0)
        return -1;
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino;
#endif
}

static int save_results(const char *path)
{
    FILE *output;
    FILE *existing = fopen(path, "rb");
    char buffer[4096];
    size_t count;
    int ok = 1;

    if (existing != NULL) {
        int match = same_file(yyin, existing);
        fclose(existing);
        if (match != 0) {
            fputs(match > 0 ? "Source and output must be different files.\n"
                           : "Could not check the output file's identity.\n", stderr);
            return 0;
        }
    }

    if (ferror(results) || fflush(results) != 0 || fseek(results, 0, SEEK_SET) != 0) {
        fputs("Could not prepare the program results.\n", stderr);
        return 0;
    }

    output = fopen(path, "w");
    if (output == NULL) {
        perror(path);
        return 0;
    }
    while ((count = fread(buffer, 1, sizeof(buffer), results)) > 0) {
        if (fwrite(buffer, 1, count, output) != count) {
            ok = 0;
            break;
        }
    }
    if (ferror(results))
        ok = 0;
    if (fclose(output) != 0)
        ok = 0;
    if (!ok)
        fprintf(stderr, "Could not write all results to '%s'.\n", path);
    return ok;
}

int main(int argc, char *argv[])
{
    int result;

    if (argc > 3) {
        fprintf(stderr, "Usage: %s [source_file [output_file]]\n", argv[0]);
        return 1;
    }

    yyin = stdin;
    if (argc >= 2) {
        yyin = fopen(argv[1], "r");
        if (yyin == NULL) {
            perror(argv[1]);
            return 1;
        }
    }

    results = stdout;
    if (argc == 3) {
        /* Keep the previous output file until the new program succeeds. */
        results = tmpfile();
        if (results == NULL) {
            perror("Temporary output");
            fclose(yyin);
            return 1;
        }
    }

    result = yyparse();
    if (argc == 3) {
        if (result == 0 && !save_results(argv[2]))
            result = 1;
        fclose(results);
    }
    if (yyin != stdin)
        fclose(yyin);
    return result;
}
