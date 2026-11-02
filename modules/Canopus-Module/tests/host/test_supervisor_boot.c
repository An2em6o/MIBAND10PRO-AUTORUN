/* Fresh process per run: START_BOOT is deliberately one-shot per resident load.
 * Uses the real CPC2 device path, boot state machine and service dispatch. */
#include "canopus_test.h"
#include "canopus_supervisor.h"
#include "canopus_supervisor_boot.h"
#include "canopus_supervisor_platform.h"
#include "canopus_runtime.h"
#include <string.h>

static struct canopus_supervisor_v1 sup;
static uint32_t now_ms, steps[8], step_count;
static int screen = 2, inside_activation, posted, timers, removed;
static int foreground_starts, background_starts;
static void (*foreground)(void *), (*background)(void *);
static void *foreground_data, *background_data;

static uint32_t monotonic_ms(void *cookie)
{
    (void)cookie;
    return now_ms;
}

static int screen_state(void *cookie)
{
    (void)cookie;
    return screen;
}

static int start_foreground(void *cookie, void (*poll)(void *), void *data)
{
    (void)cookie;
    foreground_starts++;
    foreground = poll;
    foreground_data = data;
    return 0;
}

static int start_background(void *cookie, void (*poll)(void *), void *data)
{
    (void)cookie;
    background_starts++;
    background = poll;
    background_data = data;
    return 0;
}

static void record_step(uint32_t step)
{
    CHECK(step_count < sizeof(steps) / sizeof(steps[0]));
    if (step_count < sizeof(steps) / sizeof(steps[0])) steps[step_count++] = step;
}

static int stage_package(void *cookie, const char *token, uint32_t stage)
{
    (void)cookie;
    CHECK(token == 0);
    CHECK(!inside_activation);
    record_step(stage);
    return 0;
}

static int persist(void *cookie, const uint8_t *data, uint32_t size)
{
    (void)cookie;
    CHECK(data != 0);
    CHECK_EQ(size, CANOPUS_SUP_REGISTRY_SIZE);
    return 0;
}

static int remove_pending(void *cookie, const char *path)
{
    (void)cookie;
    CHECK(strcmp(path, "/data/canopus/boot.pending") == 0);
    removed++;
    return 0;
}

static void posted_work(const struct canopus_context_v1 *ctx, void *user)
{
    (void)ctx; (void)user;
    CHECK(!inside_activation);
    posted++;
}

static void timer_work(const struct canopus_context_v1 *ctx, int32_t id, void *user)
{
    (void)ctx; (void)id; (void)user;
    CHECK(!inside_activation);
    timers++;
}

static int activate(const struct canopus_context_v1 *ctx)
{
    uint32_t before;
    int32_t timer;
    CHECK(!inside_activation);
    inside_activation = 1;
    record_step(3u); /* restored module activation, between stages 2 and 1 */
    before = step_count;
    CHECK_EQ(ctx->ui->post(ctx, posted_work, 0), 0);
    timer = ctx->time->timer_create(ctx, 1u, 0, timer_work, 0);
    CHECK(timer >= 0);
    CHECK_EQ(ctx->time->timer_set_background(ctx, timer, 1), 0);
    CHECK_EQ(ctx->time->timer_start(ctx, timer), 0);

    /* Make both the next boot stage and module timer due while this callback
     * is still active. All nested poll entry points must remain guarded. */
    now_ms += 1000u;
    foreground(foreground_data);
    background(background_data);
    canopus_supervisor_timers_poll(&sup);
    CHECK_EQ(step_count, before);
    CHECK_EQ(posted, 0);
    CHECK_EQ(timers, 0);
    inside_activation = 0;
    return 0;
}

static int module_noop(const struct canopus_context_v1 *ctx)
{
    (void)ctx;
    return 0;
}

static int module_query(struct canopus_status_writer_v1 *writer)
{
    (void)writer;
    return 0;
}

static const struct canopus_module_descriptor_v1 descriptor = {
    .struct_size = sizeof(struct canopus_module_descriptor_v1),
    .abi_major = CANOPUS_ABI_MAJOR,
    .abi_minor = CANOPUS_ABI_MINOR,
    .module_id = "boot_test",
    .target_id = CANOPUS_PORTABLE_TARGET_ID,
    .prepare = module_noop,
    .activate = activate,
    .deactivate = module_noop,
    .stop = module_noop,
    .query = module_query,
};

static int load_module(void *cookie, uint32_t slot, const char *id, uint32_t lifecycle)
{
    (void)cookie; (void)lifecycle;
    sup.loading_slot = (int32_t)slot;
    CHECK_EQ(canopus_supervisor_register_descriptor(&sup, id, &descriptor), 0);
    sup.loading_slot = -1;
    return CANOPUS_STATE_READY;
}

static uint32_t boot_phase(void)
{
    uint32_t status;
    CHECK_EQ(canopus_supervisor_boot_query(&sup, &status), 0);
    return status >> 8;
}

static void arm(uint32_t request_id)
{
    uint8_t request[CANOPUS_TRANSPORT_V2_HEADER_SIZE];
    uint8_t response[CANOPUS_TRANSPORT_V2_HEADER_SIZE];
    struct canopus_proto_request_v1 req = {
        CANOPUS_PROTO_MAGIC, CANOPUS_PROTO_REQUEST_SIZE,
        CANOPUS_ABI_MAJOR, CANOPUS_ABI_MINOR, CANOPUS_CMD_START_BOOT, 0u, 0u, 0u
    };
    struct canopus_proto_response_v1 resp;
    uint32_t opcode, offset;
    req.request_id = request_id;
    CHECK_EQ(canopus_transport_v2_encode_request(&req, 0, request, sizeof(request)),
             (int)sizeof(request));
    CHECK_EQ(canopus_supervisor_device_write(&sup, request, sizeof(request)),
             (int32_t)sizeof(request));
    CHECK_EQ(canopus_supervisor_device_read(&sup, response, sizeof(response)),
             (int32_t)sizeof(response));
    CHECK_EQ(canopus_transport_v2_decode_response(response, sizeof(response),
                 &resp, &opcode, &offset), 0);
    CHECK_EQ(opcode, CANOPUS_CMD_START_BOOT);
    CHECK_EQ(resp.request_id, request_id);
    CHECK_EQ(resp.result_state, CANOPUS_RESULT_COMPLETED);
}

static void background_sequence(void)
{
    arm(1u);
    CHECK_EQ(step_count, 0u);
    CHECK_EQ(foreground_starts, 0);
    CHECK_EQ(background_starts, 1);
    CHECK_EQ(canopus_supervisor_start_foreground(&sup), 0);
    now_ms = 1000u;
    background(background_data); /* lit: retain the existing 3s settle */
    foreground(foreground_data);
    CHECK_EQ(step_count, 0u);
    screen = 0;
    now_ms = 3999u;
    background(background_data);
    CHECK_EQ(step_count, 0u);
    now_ms = 4000u;
    foreground(foreground_data);
    canopus_supervisor_timers_poll(&sup);
    CHECK_EQ(step_count, 0u); /* these sources cannot bypass the policy */
    background(background_data);
    CHECK_EQ(step_count, 1u);
    background(background_data);
    CHECK_EQ(step_count, 1u);
    arm(2u);
    CHECK_EQ(boot_phase(), 2u);
    screen = 1;
    now_ms = 5000u;
    background(background_data);
    CHECK_EQ(step_count, 1u);
    screen = 0;
    now_ms = 7999u;
    background(background_data);
    CHECK_EQ(step_count, 1u);
    now_ms = 8000u;
    background(background_data);
    CHECK_EQ(step_count, 2u);
    CHECK_EQ(removed, 1);
    now_ms = 9000u;
    background(background_data); /* activation attempts nested polls */
    CHECK_EQ(step_count, 3u);
    CHECK_EQ(posted, 0);
    CHECK_EQ(timers, 1); /* existing background timer dispatch stays intact */
    foreground(foreground_data);
    CHECK_EQ(posted, 1);
    CHECK_EQ(step_count, 3u);
    background(background_data);
    CHECK_EQ(step_count, 4u);
    now_ms += 1000u;
    background(background_data);
    CHECK_EQ(step_count, 5u);
    now_ms += 1000u;
    background(background_data);
    CHECK_EQ(boot_phase(), 0u);
    arm(3u);
    now_ms += 10000u;
    background(background_data);
    CHECK_EQ(step_count, 5u);
    CHECK_EQ(background_starts, 1);
}

int main(int argc, char **argv)
{
    struct canopus_sup_platform_v1 platform = {
        .target_id = "xiaomi-band-10-pro-3.101.043",
        .load_module = load_module,
        .stage_package = stage_package,
        .persist = persist,
        .file_remove = remove_pending,
        .monotonic_ms = monotonic_ms,
        .screen_state = screen_state,
        .start_timer_pump = start_foreground,
        .start_background_pump = start_background,
    };
    static const uint32_t expected[] = {0u, 2u, 3u, 1u, 2u};
    int legacy_background = 0;
    if (argc != 2) return 2;
    if (strcmp(argv[1], "036") == 0)
        platform.target_id = "xiaomi-band-10-pro-3.101.036";
    else if (strcmp(argv[1], "155") == 0) {
        platform.target_id = "xiaomi-band-11-4.100.155";
        legacy_background = 1;
    } else if (strcmp(argv[1], "179") == 0) {
        platform.target_id = "xiaomi-band-11-4.100.179";
        legacy_background = 1;
    } else if (strcmp(argv[1], "043") != 0) return 2;
    test_set_current(platform.target_id);
    CHECK_EQ(canopus_supervisor_init(&sup, 1u, &platform, 0), 0);
    CHECK_EQ(canopus_supervisor_add_module(&sup,
        CANOPUS_LIFECYCLE_RESIDENT_AFTER_ACTIVATION, 1u, "boot_test"), 0);
    sup.modules[0].intent = CANOPUS_SUP_INTENT_ENABLED;

    if (legacy_background) {
        background_sequence();
        CHECK(memcmp(steps, expected, sizeof(expected)) == 0);
        printf("%s START_BOOT %s background regression: %d checks, %d failures\n",
               g_failures ? "FAIL" : "PASS", argv[1], g_checks, g_failures);
        return g_failures != 0;
    }

    arm(1u);
    CHECK_EQ(step_count, 0u); /* shell write/read returned without native work */
    CHECK_EQ(foreground_starts, 1);
    CHECK_EQ(background_starts, 0);
    CHECK_EQ(boot_phase(), 1u);
    CHECK_EQ(canopus_supervisor_start_background(&sup), 0);
    now_ms = 999u;
    foreground(foreground_data);
    CHECK_EQ(step_count, 0u);

    now_ms = 1000u;
    background(background_data);
    canopus_supervisor_timers_poll(&sup);
    CHECK_EQ(step_count, 0u);
    foreground(foreground_data); /* screen=2 must not postpone forever */
    CHECK_EQ(step_count, 1u);
    foreground(foreground_data); /* same timestamp: no second step */
    CHECK_EQ(step_count, 1u);
    arm(1u);
    arm(2u);
    CHECK_EQ(foreground_starts, 1);
    CHECK_EQ(boot_phase(), 2u);

    screen = 1;
    now_ms = 2000u;
    foreground(foreground_data);
    CHECK_EQ(step_count, 2u);
    CHECK_EQ(removed, 1);
    screen = 0;
    now_ms = 10000u;
    background(background_data); /* suspended LVGL: no foreground callback */
    canopus_supervisor_timers_poll(&sup);
    CHECK_EQ(step_count, 2u);
    CHECK_EQ(boot_phase(), 3u);

    screen = 2;
    foreground(foreground_data); /* wake resumes one step, not a catch-up loop */
    CHECK_EQ(step_count, 3u);
    CHECK_EQ(posted, 0); /* activation posts belong to the following heartbeat */
    CHECK_EQ(timers, 0);
    background(background_data);
    canopus_supervisor_timers_poll(&sup);
    CHECK_EQ(step_count, 3u);
    CHECK_EQ(posted, 0);
    CHECK_EQ(timers, 1); /* background module timers still run */
    foreground(foreground_data);
    CHECK_EQ(posted, 1);
    CHECK_EQ(step_count, 4u);
    foreground(foreground_data);
    CHECK_EQ(step_count, 4u);
    now_ms += 1000u;
    foreground(foreground_data);
    CHECK_EQ(step_count, 5u);
    CHECK(memcmp(steps, expected, sizeof(expected)) == 0);
    now_ms += 1000u;
    foreground(foreground_data);
    CHECK_EQ(boot_phase(), 0u);
    arm(3u);
    now_ms += 10000u;
    foreground(foreground_data);
    CHECK_EQ(step_count, 5u);
    CHECK_EQ(foreground_starts, 1);
    CHECK_EQ(posted, 1);
    printf("%s START_BOOT %s foreground regression: %d checks, %d failures\n",
           g_failures ? "FAIL" : "PASS", argv[1], g_checks, g_failures);
    return g_failures != 0;
}
