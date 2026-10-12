# AdaLogic BASIC - Language Reference
Automated syntax and usage guide for AI context.

## 1. Lexical Tokens & Keywords
* `TOK_DECLAREMODULE`
* `TOK_MODULE`
* `TOK_ENDMODULE`
* `TOK_IMPORT`
* `TOK_VERSION`
* `TOK_ERROR`
* `TOK_NUMBER`
* `TOK_HEX_LITERAL`
* `TOK_BIN_LITERAL`
* `TOK_STRING`
* `TOK_CONST_ID`
* `TOK_ATOM`
* `TOK_LOGIC_VAR`
* `TOK_FINDALL`
* `TOK_CONSTRAINT`
* `TOK_PREDICATE`
* `TOK_RULE`
* `TOK_ASSERT`
* `TOK_RETRACT`
* `TOK_UPDATE`
* `TOK_MATCH`
* `TOK_CHANGE`
* `TOK_L_PAREN`
* `TOK_R_PAREN`
* `TOK_L_SQUARE`
* `TOK_R_SQUARE`
* `TOK_COMMA`
* `TOK_DOT`
* `TOK_ADDRESSOF`
* `TOK_HORN_CLAUSE`
* `TOK_QUERY`
* `TOK_RND`
* `TOK_DELAY`
* `TOK_LOCATE`
* `TOK_ASSIGN`
* `TOK_PLUS`
* `TOK_MINUS`
* `TOK_MUL`
* `TOK_DIV`
* `TOK_MOD`
* `TOK_LESS`
* `TOK_GREATER`
* `TOK_LESS_EQUAL`
* `TOK_GREATER_EQUAL`
* `TOK_EQUAL`
* `TOK_NOT_EQUAL`
* `TOK_NOT`
* `TOK_AND`
* `TOK_OR`
* `TOK_XOR`
* `TOK_SHL`
* `TOK_SHR`
* `TOK_LET`
* `TOK_AS`
* `TOK_PRINT`
* `TOK_PRINT_STR`
* `TOK_INPUT`
* `TOK_LEN`
* `TOK_MID`
* `TOK_LEFT`
* `TOK_RIGHT`
* `TOK_TRY`
* `TOK_CATCH`
* `TOK_THROW`
* `TOK_IF`
* `TOK_ELSE`
* `TOK_THEN`
* `TOK_FOR`
* `TOK_TO`
* `TOK_BEGIN`
* `TOK_END`
* `TOK_REPEAT`
* `TOK_UNTIL`
* `TOK_WHILE`
* `TOK_SELECT`
* `TOK_CHOOSE`
* `TOK_CASE`
* `TOK_ARROW`
* `TOK_PIPE`
* `TOK_RETURN`
* `TOK_TRUE`
* `TOK_FALSE`
* `TOK_FOREACH`
* `TOK_PROVE`
* `TOK_IN`
* `TOK_OUT`
* `TOK_REQUIRE`
* `TOK_ENSURE`
* `TOK_STRICT`
* `TOK_SLIDE`
* `TOK_CLAIM`
* `TOK_BIND`
* `TOK_DROP`
* `TOK_SWEEP`
* `TOK_PEEK`
* `TOK_POKE`
* `TOK_DEREF`
* `TOK_STEP`
* `TOK_SIZEOF`
* `TOK_OFFSETOF`
* `TOK_TYPEOF`
* `TOK_OCTAL_LITERAL`
* `TOK_STRING_TYPE`
* `TOK_READLINE`
* `TOK_BITFIELD`
* `TOK_COLON`
* `TOK_CUT`
* `TOK_PROCEDURE`
* `TOK_FUNCTION`
* `TOK_CALL`
* `TOK_LOAD`
* `TOK_INTO`
* `TOK_FLUSH`
* `TOK_OPEN`
* `TOK_READ`
* `TOK_WRITE`
* `TOK_CLOSE`
* `TOK_STRUCT`
* `TOK_KNOWS`
* `TOK_FIND`
* `TOK_IS`
* `TOK_INCLUDE`
* `TOK_SPAWN`
* `TOK_SYNC`
* `TOK_ATOMIC`
* `TOK_FLOAT2`
* `TOK_FLOAT4`
* `TOK_MAT2`
* `TOK_MAT3`
* `TOK_MAT4`
* `TOK_SPLAT`
* `TOK_FMA`
* `TOK_LERP`
* `TOK_CLAMP`
* `TOK_DOT_PROD`
* `TOK_CROSS`
* `TOK_NORMALIZE`
* `TOK_BLEND`
* `TOK_CREATE_WINDOW`
* `TOK_TICK`
* `TOK_ON`
* `TOK_PAINT`
* `TOK_COLOR`
* `TOK_CLEAR`
* `TOK_DRAW`
* `TOK_FILL`
* `TOK_RECT`
* `TOK_LINE`
* `TOK_CIRCLE`
* `TOK_TRIANGLE`
* `TOK_POLY`
* `TOK_PLOT`
* `TOK_PIXEL`
* `TOK_TEXT`
* `TOK_READ_PIXEL`
* `TOK_SET_ALPHA`
* `TOK_SET_CLIP`
* `TOK_SET_ORIGIN`
* `TOK_SYS_RENDERER`
* `TOK_KEY`
* `TOK_MOUSE_X`
* `TOK_MOUSE_Y`
* `TOK_MOUSE_CLICK`
* `TOK_SCREEN_WIDTH`
* `TOK_SCREEN_HEIGHT`
* `TOK_VIRTUAL_WIDTH`
* `TOK_VIRTUAL_HEIGHT`
* `TOK_VMOUSE_X`
* `TOK_VMOUSE_Y`
* `TOK_MOUSE`
* `TOK_MSG_BOX`
* `TOK_CEASE`
* `TOK_LISTEN`
* `TOK_PLAY`
* `TOK_SOUND`
* `TOK_BREAK`
* `TOK_CONTINUE`
* `TOK_ENUM`
* `TOK_CAST`

## 2. Core Data Types
* `TYPE_NONE`
* `TYPE_U8`
* `TYPE_U16`
* `TYPE_U32`
* `TYPE_U64`
* `TYPE_U128`
* `TYPE_S8`
* `TYPE_S16`
* `TYPE_S32`
* `TYPE_S64`
* `TYPE_S128`
* `TYPE_F32`
* `TYPE_F64`
* `TYPE_F128`
* `TYPE_F32X2`
* `TYPE_F32X4`
* `TYPE_U32X4`
* `TYPE_S32X4`
* `TYPE_MAT2X2`
* `TYPE_MAT3X3`
* `TYPE_MAT4X4`
* `TYPE_BOOLEAN`
* `TYPE_CHAR`
* `TYPE_REFERENCE`
* `TYPE_PURE`
* `TYPE_HW8`
* `TYPE_HW16`
* `TYPE_HW32`
* `TYPE_HW64`
* `TYPE_BINARY`

## 3. Abstract Syntax Tree (Grammar Nodes)
* `AST_NULL`
* `AST_DECLAREMODULE`
* `AST_MODULE`
* `AST_IMPORT`
* `AST_VERSION`
* `AST_PROGRAM`
* `AST_LET_STMT`
* `AST_PRINT_STMT`
* `AST_PRINT_STR_STMT`
* `AST_INPUT_STMT`
* `AST_IF_STMT`
* `AST_CHOOSE`
* `AST_FOR_STMT`
* `AST_FOREACH_STMT`
* `AST_STEP_STMT`
* `AST_BREAK_STMT`
* `AST_CONTINUE_STMT`
* `AST_CAST_EXPR`
* `AST_BLOCK_STMT`
* `AST_REPEAT_STMT`
* `AST_STRICT_STMT`
* `AST_SLIDE_STMT`
* `AST_CLAIM_STMT`
* `AST_BIND_STMT`
* `AST_DROP_STMT`
* `AST_SWEEP_STMT`
* `AST_POKE_STMT`
* `AST_PEEK_EXPR`
* `AST_DEREF_EXPR`
* `AST_SELECT_STMT`
* `AST_CASE_STMT`
* `AST_PROCEDURE_DECL`
* `AST_FUNCTION_DECL`
* `AST_CALL_STMT`
* `AST_STR_LEN`
* `AST_STR_LEFT`
* `AST_STR_RIGHT`
* `AST_STR_MID`
* `AST_STR_CONCAT`
* `AST_SIZEOF_EXPR`
* `AST_OFFSETOF_EXPR`
* `AST_TYPEOF_EXPR`
* `AST_RUNTIME_ASSERT`
* `AST_RND_EXPR`
* `AST_DELAY_STMT`
* `AST_LOCATE_STMT`
* `AST_TRY_STMT`
* `AST_THROW_STMT`
* `AST_KNOWS_FACT`
* `AST_KNOWS_QUERY`
* `AST_FIND_QUERY`
* `AST_FINDALL_QUERY`
* `AST_CONSTRAINT_DECL`
* `AST_PREDICATE_DECL`
* `AST_RULE_DECL`
* `AST_ASSERT_STMT`
* `AST_RETRACT_STMT`
* `AST_UPDATE_STMT`
* `AST_MATCH_STMT`
* `AST_KNOWS_CHANGE`
* `AST_RETURN_STMT`
* `AST_STRUCT_DECL`
* `AST_MEMBER_EXPR`
* `AST_ADDRESSOF`
* `AST_NOT`
* `AST_UNARY_MINUS`
* `AST_WHILE_STMT`
* `AST_FUNC_CALL`
* `AST_ARG_LIST`
* `AST_ARRAY_ACCESS`
* `AST_ARRAY_ASSIGN`
* `AST_LOAD_STMT`
* `AST_FLUSH_STMT`
* `AST_INCLUDE_STMT`
* `AST_FILE_OPEN`
* `AST_FILE_READ`
* `AST_FILE_WRITE`
* `AST_FILE_CLOSE`
* `AST_BINOP`
* `AST_NUMBER_EXPR`
* `AST_HEX_EXPR`
* `AST_BIN_EXPR`
* `AST_OCTAL_EXPR`
* `AST_STRING_EXPR`
* `AST_CONST_REF`
* `AST_CONST_DECL`
* `AST_VAR_EXPR`
* `AST_CONSTRUCTOR`
* `AST_TRUE`
* `AST_FALSE`
* `AST_ENUM_DECL`
* `AST_PARAM_DECL`
* `AST_REQUIRE_CLAUSE`
* `AST_ENSURE_CLAUSE`
* `AST_STRING_DECL`
* `AST_READLINE_STMT`
* `AST_BITFIELD_DECL`
* `AST_CUT_STMT`
* `AST_SPAWN_STMT`
* `AST_SYNC_STMT`
* `AST_ATOMIC_BLOCK`
* `AST_HORN_CLAUSE`
* `AST_QUERY`
* `AST_FACT`
* `AST_PREDICATE`
* `AST_LOGIC_VAR`
* `AST_SIMD_INTRINSIC`
* `AST_CREATE_WINDOW`
* `AST_TICK`
* `AST_ON_BLOCK`
* `AST_COLOR`
* `AST_CLEAR`
* `AST_DRAW`
* `AST_FILL`
* `AST_PLOT`
* `AST_READ_PIXEL`
* `AST_SET_ALPHA`
* `AST_SET_CLIP`
* `AST_SET_ORIGIN`
* `AST_SYS_RENDERER`
* `AST_KEY_STATE`
* `AST_MOUSE_X`
* `AST_MOUSE_Y`
* `AST_MOUSE_CLICK`
* `AST_VMOUSE_X`
* `AST_VMOUSE_Y`
* `AST_SCREEN_WIDTH`
* `AST_SCREEN_HEIGHT`
* `AST_VIRTUAL_WIDTH`
* `AST_VIRTUAL_HEIGHT`
* `AST_TEXT`
* `AST_MSG_BOX`
* `AST_LISTEN`
* `AST_CEASE`
* `AST_PLAY_SOUND`
* `AST_ATOM`

## 4. Syntax Templates (The Gold Standard)
AI MODULE INSTRUCTION: Ye MUST follow these structural blueprints exactly. Zero deviations.
1. NEVER invent keywords (e.g., use 'AS' instead of 'RETURNS').
2. 'LET' is optional for assignments if the Oracle can infer the type. Mutations DO NOT require 'LET' (e.g., x = 10).
3. Every 'IF' and 'FOR' statement MUST be followed by the 'THEN' keyword. 'WHILE' loops DO NOT use 'THEN'.
4. Variables MUST be declared at the top of a block. Use 'AS <Type>' ONLY if the variable is uninitialized (e.g., LET state AS Battle_Flags). Otherwise, let the Oracle infer it (e.g., LET score = 100).
5. MODULE blocks MUST end with 'ENDMODULE'.
6. Subprogram blocks explicitly close with 'END FUNCTION' or 'END PROCEDURE'. 'WHILE' loops close with 'END WHILE'.
7. NAKED CALLS are fully supported! Ye can call procedures directly without a dummy variable (e.g., Audio.PlayTheme()).
8. Use PRINT$ for strings and PRINT for numbers. Use the '|' pipe operator tae chain them elegantly (e.g., PRINT$ "HP: " | Health).
9. In SELECT statements, each CASE only accepts a SINGLE statement. If you need multiple statements in a CASE, wrap them in BEGIN...END.
11. PURE natively supports +, -, *, /. The Oracle automatically safely routes these. There is NO native POW() function.
12. Use explicit type constructors for literals when needed: U8(), HW8(), U16(), U32(), U64(), U128(), S32(), F64().
13. Use $ for Hexadecimal ($FF) and % for Binary (%1010_1010).
14. READLINE can be used completely naked tae pause execution, or with a target variable (e.g., READLINE input_var).
15. Use the CHOOSE(condition, true_val, false_val) macro for inline ternary operations and string assignments.
16. Use the MATCH / END MATCH structure for fast, single-line value routing.
17. Use ASSERT <flag> and ?- <flag> for global boolean logic state tracking (Prolog-style).
18. Arrays MUST be declared globally using STRICT name[size] or SLIDE name[max, window].
18.5. Use CLAIM, BIND, DROP, and SWEEP for static, heap-free garbage collection (The Dumptruck).
19. Hardware SIMD Vectors (F32x4, etc.) use intrinsic constructors: SPLAT(), FMA(), DOT(), CROSS(), LERP(), CLAMP(), NORMALIZE(), BLEND().
20. In Native 2D Rendering, use CREATE_WINDOW and the ON TICK / ON PAINT event blocks. Use CLEAR and COLOR before DRAW or FILL operations.
21. Use TRY / CATCH / THROW for native error handling.
22. String intrinsics include LEN(), LEFT(), RIGHT(), and MID().
23. File I/O uses OPEN(), WRITE, and CLOSE.
24. Pointers use @ for AddressOf, PEEK(), and POKE for memory access, with SIZEOF() and TYPEOF() for reflection.

### A. Modules, Structs, and Bitfields
```basic
DECLAREMODULE System_Types
VERSION 1.0

STRUCT Compact_State
    BITFIELD Active : 1
    BITFIELD Mode   : 3
END

STRUCT Entity
    HP AS U64
END
ENDMODULE
```

### B. Assignments & Oracle Inference
```basic
LET x = 100            -- Oracle infers U64
LET my_entity AS Entity -- Uninitialized structs need explicit AS
my_entity.HP = 50       -- Mutations dinna need LET
```

### C. Subprograms & Naked Calls
```basic
FUNCTION Calculate(val AS U64) AS U64
BEGIN
    RETURN val * 2
END FUNCTION

PROCEDURE LogState(status AS U64)
BEGIN
    PRINT$ "Status Code: " | status
    READLINE -- Naked Readline pauses execution
END PROCEDURE
```

### D. Control Flow & Loop Mutations
```basic
PROCEDURE ControlDemo()
BEGIN
    LET i = 0
    LET choice = 2

    -- IF and FOR use THEN
    FOR i = 1 TO 5 THEN
        IF i == 3 THEN
            PRINT i
        END IF
    END FOR

    -- WHILE does NOT use THEN
    WHILE i < 10
        i = i + 1 -- Naked mutation
    END WHILE

    -- SELECT / CASE (Multiple statements require BEGIN/END)
    SELECT choice
    CASE 1
        PRINT$ "One Statement"
    CASE 2
        BEGIN
            PRINT$ "Two Statements"
            i = 0
        END
    END SELECT
END PROCEDURE
```

### E. Multi-Core Dispatch (SPAWN, SYNC, ATOMIC)
```basic
LET Shared_Counter = 0

PROCEDURE Background_Task(val AS U64)
BEGIN
    ATOMIC
        Shared_Counter = Shared_Counter + val
    END
END PROCEDURE

BEGIN
    SPAWN Background_Task(10)
    SPAWN Background_Task(20)
    SYNC -- Wait for background tasks to finish
    PRINT Shared_Counter
END
```

### F. Knowledge Base and Logic
```basic
PREDICATE is_valid(U64)
ASSERT is_valid(1).

LET check = ?-is_valid(1)
```

### G. Execution and Naked Module Calls
```basic
MODULE My_Logic
    PROCEDURE Startup()
    BEGIN
        PRINT$ "Engine Active"
    END PROCEDURE
ENDMODULE

-- Preferred way tae start a program:
BEGIN
    My_Logic.Startup() -- Naked Call!
END
```

### H. Safe Math & Flatline Rules
```basic
PROCEDURE MathDemo()
BEGIN
    LET t = S32(5)
    LET result AS S32

    -- RULE: NO Floats! Unary minus is natively supported.
    -- BAD:  result = 0.5 * EXP(-t)
    -- GOOD: result = (1 / 2) * EXP(-t)
    result = (1 / 2) * EXP(-t)
END PROCEDURE
```

### J. Includes and Imports
```basic
-- RULE: Ye MUST INCLUDE the file before ye IMPORT the module!
INCLUDE "MY_LIB.ALBI"
IMPORT My_Logic
```

### K. The CHOOSE Macro (Inline Ternary)
```basic
PROCEDURE ChooseDemo()
BEGIN
    LET Weather = 2
    -- Use CHOOSE for fast inline logic instead of heavy IF blocks
    LET WStr = CHOOSE(Weather == 1, "Clear Skies", CHOOSE(Weather == 2, "Thick Mud", "Rain"))
    PRINT$ WStr
END PROCEDURE
```

### L. The MATCH Statement (Fast Routing)
```basic
PROCEDURE MatchDemo(Stance AS U64)
BEGIN
    -- MATCH is for single-action routing, perfect for Naked Calls!
    MATCH Stance
        1 => Audio.PlayCharge()
        2 => Audio.PlayShields()
        3 => Audio.PlayRetreat()
    END MATCH
END PROCEDURE
```

### M. Prolog-Style Global State Tracking
```basic
PROCEDURE StateDemo(Morale AS U64)
BEGIN
    -- ASSERT to inject global knowledge
    IF Morale < 40 THEN
        ASSERT Army_Broken
    ELSE
        RETRACT Army_Broken
    END IF

    -- Query the knowledge base using ?-
    LET IsBroken = ?-Army_Broken
    IF IsBroken == 1 THEN
        PRINT$ "The army is broken!"
    END IF
END PROCEDURE
```

### O. Data Types & Literals
```basic
PROCEDURE LiteralDemo()
BEGIN
    -- Use constructors to force type sizes
    LET hex_val = U8($AA)
    LET bin_val = U16(%0101_0101)
    LET big_val = U128(50000000)
    LET neg_val = S32($FFFFFF81)
END PROCEDURE
```

### P. The PURE Type (Exact Fractional Math)
```basic
PROCEDURE PureMathDemo()
BEGIN
    -- PURE(Numerator, Denominator) is a packed 64-bit integer.
    LET matter = PURE(5, 8)
    LET antimatter = PURE(1, 4)

    -- PURE natively supports natural operators.
    -- The Oracle automatically routes these tae safe fractions!
    LET mix = matter - antimatter
    
    -- The Oracle routes PRINT natively for PURE types!
    PRINT mix

    -- For exponentiation, use repeated multiplication to stay in bounds:
    LET squared = mix * mix
    PRINT squared
END PROCEDURE
```

### Q. Bitwise Operations
```basic
PROCEDURE BitwiseDemo()
BEGIN
    LET b_one = U8($AA)
    LET b_two = U8(%0101_0101)

    LET res_or = b_one OR b_two
    LET res_and = b_one AND b_two
    LET res_xor = b_one XOR b_two

    LET shift_l = U16($0001) SHL U16(%0100)
    LET shift_r = U16($0100) SHR 4
END PROCEDURE
```

### R. Arrays (STRICT and SLIDE)
```basic
-- Arrays are declared globally (outside procedures/modules)
STRICT memory_vault[4096]
SLIDE flux_buffer[8192, 1024]

PROCEDURE ArrayDemo()
BEGIN
    LET i = 0
    FOR i = 0 TO 5 THEN
        memory_vault[i] = i * 10
    END FOR
END PROCEDURE
```

### S. The Native Matrix Forge (SIMD Hardware Acceleration)
```basic
PROCEDURE SimdDemo()
BEGIN
    -- Variables map straight tae SSE/AVX hardware registers!
    LET v_zero = SPLAT(0.0)
    LET v_tens = SPLAT(10.0)
    LET v_half = SPLAT(0.5)

    -- Fused Multiply-Add (A * B + C)
    LET v_fma = FMA(v_tens, v_half, SPLAT(1.0))

    -- Geometric Operations
    LET d_val = DOT(v_tens, v_half)
    LET v_cross = CROSS(v_tens, v_half)
    LET v_lerp = LERP(v_zero, v_tens, 0.5)
    LET v_clamped = CLAMP(SPLAT(50.0), v_zero, v_tens)
    LET v_norm = NORMALIZE(v_tens)
    LET v_blend = BLEND(SPLAT(1.0), v_tens, v_zero)
END PROCEDURE
```

### T. Native 2D Rendering (Pure Procedural Graphics)
```basic
LET px = 400
LET py = 300

BEGIN
    CREATE_WINDOW "Titanium Engine Render", 800, 600

    ON TICK
        -- Hardware Keyboard Sensors (WASD = 87, 65, 83, 68. Shift = 16)
        IF KEY(68) THEN LET px = px + 5
    END

    ON PAINT
        CLEAR $000022  -- Background Hex Color
        
        COLOR $FF0000
        DRAW LINE 0, 0, VIRTUAL_WIDTH, VIRTUAL_HEIGHT
        DRAW RECT px, py, 50, 50
        
        COLOR $00FF00
        FILL CIRCLE VMOUSE_X, VMOUSE_Y, 20
        FILL TRIANGLE 100, 200, 150, 200, 125, 150
        
        COLOR $FFFFFF
        DRAW TEXT 10, 10, "Procedural Graphics!"
    END
    LISTEN
END
```

### U. Error Handling (TRY / CATCH)
```basic
PROCEDURE FileDemo()
BEGIN
    TRY
        IF 1 == 2 THEN THROW 404
    CATCH err
        PRINT$ "Caught Exception Code: " | err
    END TRY
END PROCEDURE
```

### V. Bare-Metal Memory & Pointer Arithmetic
```basic
PROCEDURE PointerDemo()
BEGIN
    LET Target = U64(1024)
    LET Addr = @Target
    
    POKE Addr, U64(2048)
    LET Val = PEEK(Addr)
    
    LET Sz = SIZEOF(Target)
    LET Typ = TYPEOF(Target)
END PROCEDURE
```

### W. String Intrinsic Forge
```basic
PROCEDURE StringDemo()
BEGIN
    LET base = "Titanium Engine"
    LET L = LEN(base)
    LET pt1 = LEFT(base, 8)
    LET pt2 = RIGHT(base, 6)
    LET pt3 = MID(base, 2, 4)
END PROCEDURE
```

### X. File I/O
```basic
PROCEDURE IODemo()
BEGIN
    LET Hnd = OPEN("save.dat", "w")
    WRITE Hnd, "Score: 100"
    CLOSE Hnd
END PROCEDURE
```

### Y. Da Dumptruck (Static Garbage Collection)
```basic
PROCEDURE GCDemo()
BEGIN
    LET parent_node = 0
    LET child_node = 0

    -- Grab nodes frae da static pool
    CLAIM parent_node
    CLAIM child_node

    -- Link them sae dropping the parent cascades tae the child
    BIND parent_node TO child_node

    -- Drop the parent (child dies automatically)
    DROP parent_node

    -- Run the steady shovel to recycle memory incrementally
    SWEEP 5
END PROCEDURE
```

