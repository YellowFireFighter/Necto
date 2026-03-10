// ============================================================
//  RL Position Overlay — v8
// ============================================================

const uint64 GNAMES_OFF    = 0x23F0850;
const uint64 GOBJECTS_OFF  = 0x23F0898;
const uint64 UOBJ_NAMEIDX  = 0x48;
const uint64 UOBJ_CLASS    = 0x50;
const uint64 FNAME_STR_OFF = 0x18;
const uint64 POS_OFF       = 0x090;
const uint64 PC_CAR_PTR    = 0x280;

const int    STALE_TICKS   = 120;   // 2s at 60fps
const int    COOLDOWN      = 30;

proc_t  g_proc;
uint64  g_base, g_gnames, g_gobjects;

uint64  g_ball_obj   = 0;
uint64  g_pc_obj     = 0;
bool    g_found_ball = false;
bool    g_found_pc   = false;
uint64  g_font       = 0;

int     g_ball_cooldown    = 0;
int     g_pc_cooldown      = 0;
int     g_ball_still_ticks = 0;
float   g_ball_last_x = 0, g_ball_last_y = 0, g_ball_last_z = 0;

// ── Helpers ───────────────────────────────────────────────────

bool is_valid_ptr(uint64 p)
{
    if (p == 0 || (p & 1) != 0) return false;
    if (p < 0x10000 || p > 0x7FFFFFFFFFFF) return false;
    return true;
}

string get_name_by_idx(int32 idx)
{
    if (idx < 0 || idx > 600000) return "";
    uint64 arr = g_proc.ru64(g_gnames);
    uint64 ne  = g_proc.ru64(arr + uint64(idx) * 8);
    if (!is_valid_ptr(ne)) return "";
    return g_proc.rws(ne + FNAME_STR_OFF, 128);
}

string get_class_name(uint64 obj)
{
    uint64 cls = g_proc.ru64(obj + UOBJ_CLASS);
    if (!is_valid_ptr(cls)) return "";
    return get_name_by_idx(g_proc.r32(cls + UOBJ_NAMEIDX));
}

bool is_valid_arena_pos(float x, float y, float z)
{
    if (x != x || y != y || z != z) return false;
    if (x < -7000.0f || x > 7000.0f) return false;
    if (y < -8000.0f || y > 8000.0f) return false;
    if (z < -500.0f  || z > 4000.0f) return false;
    if (x == 0.0f && y == 0.0f && z == 0.0f) return false;
    return true;
}

bool read_pos(uint64 obj, float &out x, float &out y, float &out z)
{
    x = g_proc.rf32(obj + POS_OFF);
    y = g_proc.rf32(obj + POS_OFF + 4);
    z = g_proc.rf32(obj + POS_OFF + 8);
    return is_valid_arena_pos(x, y, z);
}

// ── Scanners ──────────────────────────────────────────────────

void find_ball()
{
    int32  total = g_proc.r32(g_gobjects + 8);
    uint64 objs  = g_proc.ru64(g_gobjects);
    g_found_ball       = false;
    g_ball_still_ticks = 0;

    for (int32 i = 0; i < total; i++)
    {
        uint64 obj = g_proc.ru64(objs + uint64(i) * 8);
        if (!is_valid_ptr(obj)) continue;
        if (get_class_name(obj) != "Ball_TA") continue;

        float x, y, z;
        if (read_pos(obj, x, y, z))
        {
            g_ball_obj = obj;
            g_found_ball = true;
            g_ball_last_x = x; g_ball_last_y = y; g_ball_last_z = z;
            log_console("[Overlay] Ball -> 0x" + formatUInt(obj, "0H", 16)
                + "  pos=" + int(x) + "," + int(y) + "," + int(z));
            return;
        }
    }
    log_console("[Overlay] Ball_TA not found");
}

void find_pc()
{
    int32  total = g_proc.r32(g_gobjects + 8);
    uint64 objs  = g_proc.ru64(g_gobjects);
    g_found_pc = false;

    for (int32 i = 0; i < total; i++)
    {
        uint64 obj = g_proc.ru64(objs + uint64(i) * 8);
        if (!is_valid_ptr(obj)) continue;
        if (get_class_name(obj) != "PlayerController_TA") continue;

        string oname = get_name_by_idx(g_proc.r32(obj + UOBJ_NAMEIDX));
        if (oname.findFirst("Default__") >= 0) continue;

        uint64 car = g_proc.ru64(obj + PC_CAR_PTR);
        if (!is_valid_ptr(car)) continue;

        float x, y, z;
        if (read_pos(car, x, y, z))
        {
            g_pc_obj   = obj;
            g_found_pc = true;
            log_console("[Overlay] PC -> 0x" + formatUInt(obj, "0H", 16)
                + "  car=0x" + formatUInt(car, "0H", 16)
                + "  pos=" + int(x) + "," + int(y) + "," + int(z));
            return;
        }
    }
    log_console("[Overlay] PlayerController_TA not found");
}

// ── Render ────────────────────────────────────────────────────

string fmt_pos(float x, float y, float z)
{
    int ix = int(x >= 0.0f ? x + 0.5f : x - 0.5f);
    int iy = int(y >= 0.0f ? y + 0.5f : y - 0.5f);
    int iz = int(z >= 0.0f ? z + 0.5f : z - 0.5f);
    return "X:" + ix + "  Y:" + iy + "  Z:" + iz;
}

void draw_panel(float x, float y, float w, float h,
                const string &in title, const string &in value,
                uint8 tr, uint8 tg, uint8 tb)
{
    draw_rect_filled(x, y, w, h, 12, 12, 12, 210, 6.0f,
                     RR_TOP_LEFT | RR_TOP_RIGHT | RR_BOTTOM_LEFT | RR_BOTTOM_RIGHT);
    draw_rect_filled(x, y + 5, 3, h - 10, tr, tg, tb, 255, 0.0f, 0);
    draw_text(title, x + 12, y + 7,
              tr, tg, tb, 255, g_font, TE_NONE, 0, 0, 0, 0, 0.0f);
    draw_text(value, x + 12, y + 28,
              220, 220, 220, 255, g_font, TE_SHADOW, 0, 0, 0, 180, 1.0f);
}

// ── Tick ──────────────────────────────────────────────────────

void on_tick(int id, int data_index)
{
    const float PAD_X   = 12.0f;
    const float PAD_Y   = 12.0f;
    const float PANEL_W = 300.0f;
    const float PANEL_H = 56.0f;
    const float GAP     = 8.0f;

    if (g_ball_cooldown > 0) g_ball_cooldown--;
    if (g_pc_cooldown   > 0) g_pc_cooldown--;

    // ── Car ───────────────────────────────────────────────────
    string car_str = "searching...";
    float  cx = 0, cy = 0, cz = 0;
    bool   have_car = false;

    if (g_found_pc && is_valid_ptr(g_pc_obj))
    {
        uint64 car = g_proc.ru64(g_pc_obj + PC_CAR_PTR);
        if (is_valid_ptr(car))
        {
            if (read_pos(car, cx, cy, cz))
            {
                car_str  = fmt_pos(cx, cy, cz);
                have_car = true;
            }
            else
                car_str = "goal reset...";
        }
        else
        {
            g_found_pc = false;
            if (g_pc_cooldown == 0) { find_pc(); g_pc_cooldown = COOLDOWN; }
        }
    }
    else if (!g_found_pc && g_pc_cooldown == 0)
    {
        find_pc();
        g_pc_cooldown = COOLDOWN;
    }

    draw_panel(PAD_X, PAD_Y, PANEL_W, PANEL_H,
               "CAR POSITION", car_str, 80, 180, 255);

    // ── Ball ──────────────────────────────────────────────────
    string ball_str = "searching...";
    float  bx = 0, by = 0, bz = 0;
    bool   have_ball = false;

    if (g_found_ball && is_valid_ptr(g_ball_obj))
    {
        if (read_pos(g_ball_obj, bx, by, bz))
        {
            float dx = bx - g_ball_last_x;
            float dy = by - g_ball_last_y;
            float dz = bz - g_ball_last_z;

            if ((dx*dx + dy*dy + dz*dz) > 1.0f)
            {
                g_ball_still_ticks = 0;
                g_ball_last_x = bx; g_ball_last_y = by; g_ball_last_z = bz;
            }
            else if (++g_ball_still_ticks >= STALE_TICKS)
            {
                log_console("[Overlay] Ball stale — rescanning");
                g_found_ball       = false;
                g_ball_still_ticks = 0;
                if (g_ball_cooldown == 0) { find_ball(); g_ball_cooldown = COOLDOWN; }
                ball_str = "stale — rescanning...";
            }

            if (g_found_ball)
            {
                ball_str  = fmt_pos(bx, by, bz);
                have_ball = true;
            }
        }
        else
        {
            g_found_ball       = false;
            g_ball_still_ticks = 0;
            if (g_ball_cooldown == 0) { find_ball(); g_ball_cooldown = COOLDOWN; }
            ball_str = "goal reset...";
        }
    }
    else if (!g_found_ball && g_ball_cooldown == 0)
    {
        find_ball();
        g_ball_cooldown = COOLDOWN;
    }

    draw_panel(PAD_X, PAD_Y + PANEL_H + GAP, PANEL_W, PANEL_H,
               "BALL POSITION", ball_str, 255, 150, 40);
}

// ── Entry ─────────────────────────────────────────────────────

int main()
{
    g_font = get_font20();

    g_proc = ref_process("RocketLeague.exe");
    if (!g_proc.alive()) { log_console("[Overlay] RL not found"); return 0; }

    uint64 sz;
    if (!g_proc.get_module("RocketLeague.exe", g_base, sz))
    { log_console("[Overlay] get_module failed"); return 0; }

    g_gnames   = g_base + GNAMES_OFF;
    g_gobjects = g_base + GOBJECTS_OFF;

    log_console("[Overlay] Base=0x" + formatUInt(g_base, "0H", 16));

    find_ball();
    find_pc();

    register_callback(on_tick, 16, 0);
    return 1;
}

void on_unload()
{
    g_proc.deref();
    log_console("[Overlay] Unloaded");
}
