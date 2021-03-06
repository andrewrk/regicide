const std = @import("std");
const c = @import("c.zig");
const debug_gl = @import("debug_gl.zig");
const all_shaders = @import("all_shaders.zig");
const math3d = @import("math3d.zig");
const Vec2 = math3d.Vec2;
const Vec3 = math3d.Vec3;
const Vec4 = math3d.Vec4;
const Mat4x4 = math3d.Mat4x4;
const static_geometry = @import("static_geometry.zig");

struct PillShape {
    center: Vec2,
    /// distance from center to left/right and top/bottom of rectangle
    edge_dist: Vec2,
}

struct Platform {
    hitbox: PillShape,

    fn init(left: f32, top: f32, width: f32, height: f32) -> Platform {
        Platform {
            .hitbox = PillShape {
                .center = Vec2 {
                    .data = []f32{left + width / 2.0, top + height / 2.0},
                },
                .edge_dist = Vec2 {
                    .data = []f32{width / 2.0, height / 2.0},
                },
            },
        }
    }
}

struct KqMap {
    name: []u8,
    bg_top_color: Vec4,
    bg_bottom_color: Vec4,
    platforms: []Platform,
}

const debug_draw_platforms = !@compileVar("is_release");
const debug_platform_color = math3d.vec4(96.0/255.0, 71.0/255.0, 0.0/255.0, 1.0);
const debug_player_color = math3d.vec4(249.0/255.0, 178.0/255.0, 102.0/255.0, 1.0);

enum PlayerKind {
    Worker,
    Warrior,
    Queen,
}

enum Input {
    Left,
    Right,
    Jump,
    Down,
}

const inputs_reset = []bool{false} ** @memberCount(Input);

struct Player {
    kind: PlayerKind,
    vel: Vec2,
    hitbox: PillShape,
    alive: bool,
    inputs: [@memberCount(Input)]bool,
    inputs_last: [@memberCount(Input)]bool,

    fn pressing(self: &const Player, input: Input) -> bool {
        self.inputs[usize(input)]
    }

    fn pressedOnce(self: &const Player, input: Input) -> bool {
        const index = usize(input);
        return self.inputs[index] && !self.inputs_last[index];
    }
}

// TODO initialize with enum values as array indexes
const player_kind_sizes = []Vec2 {
    math3d.vec2(20.0, 50.0),
    math3d.vec2(20.0, 50.0),
    math3d.vec2(20.0, 50.0),
};

// TODO 10
const player_count = 1;
const fps = 60.0;
const spf = 1.0 / fps;
const gravity_accel = 10.0; // in pixels per second squared
const move_accel = 20.0; // in pixels per second squared
const y_vel_max = 10.0; // in pixels per second
const x_vel_min = -10.0; // in pixels per second
const x_vel_max = 10.0; // in pixels per second
const flap_power = 5.0;

const day_map = KqMap {
    .name = "Day Map",
    .bg_top_color = math3d.vec4(16.0/255.0, 149.0/255.0, 220.0/255.0, 1.0),
    .bg_bottom_color = math3d.vec4(97.0/255.0, 198.0/255.0, 217.0/255.0, 1.0),
    .platforms = []Platform {
        Platform.init(100.0, 100.0, 500.0, 20.0),
        Platform.init(900.0, 100.0, 500.0, 20.0),
        Platform.init(100.0, 400.0, 500.0, 20.0),
        Platform.init(900.0, 400.0, 500.0, 20.0),
    },
};

struct Regicide {
    window: &c.GLFWwindow,
    framebuffer_width: c_int,
    framebuffer_height: c_int,
    size: Vec2,
    shaders: all_shaders.AllShaders,
    projection: Mat4x4,
    static_geometry: static_geometry.StaticGeometry,
    cur_map: KqMap,
    players: [player_count]Player,
}

extern fn errorCallback(err: c_int, description: ?&const u8) {
    c.printf(c"Error: %s\n", description);
    c.abort();
}

extern fn keyCallback(window: ?&c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) {
    const reg = (&Regicide)(??c.glfwGetWindowUserPointer(window));
    const press = action == c.GLFW_PRESS;
    switch (key) {
        c.GLFW_KEY_ESCAPE => c.glfwSetWindowShouldClose(window, c.GL_TRUE),
        c.GLFW_KEY_A => playerInput(&reg.players[0], Input.Left, press),
        c.GLFW_KEY_D => playerInput(&reg.players[0], Input.Right, press),
        c.GLFW_KEY_J => playerInput(&reg.players[0], Input.Jump, press),
        c.GLFW_KEY_S => playerInput(&reg.players[0], Input.Down, press),

        else => {},
    }
}

var kq_state: Regicide = undefined;

export fn main(argc: c_int, argv: &&u8) -> c_int {
    c.glfwSetErrorCallback(errorCallback);

    if (c.glfwInit() == c.GL_FALSE) {
        c.printf(c"GLFW init failure\n");
        c.abort();
    }
    defer c.glfwTerminate();

    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 2);
    c.glfwWindowHint(c.GLFW_OPENGL_FORWARD_COMPAT, c.GL_TRUE);
    c.glfwWindowHint(c.GLFW_OPENGL_DEBUG_CONTEXT, debug_gl.is_on);
    c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);
    c.glfwWindowHint(c.GLFW_DEPTH_BITS, 0);
    c.glfwWindowHint(c.GLFW_STENCIL_BITS, 8);
    c.glfwWindowHint(c.GLFW_RESIZABLE, c.GL_FALSE);


    const window_width = 1920;
    const window_height = 1080;
    const window = c.glfwCreateWindow(window_width, window_height, c"Regicide", null, null) ?? {
        c.printf(c"unable to create window\n");
        c.abort();
    };
    defer c.glfwDestroyWindow(window);

    c.glfwSetKeyCallback(window, keyCallback);
    c.glfwMakeContextCurrent(window);
    c.glfwSwapInterval(1);

    // create and bind exactly one vertex array per context and use
    // glVertexAttribPointer etc every frame.
    var vertex_array_object: c.GLuint = undefined;
    c.glGenVertexArrays(1, &vertex_array_object);
    c.glBindVertexArray(vertex_array_object);
    defer c.glDeleteVertexArrays(1, &vertex_array_object);

    const reg = &kq_state;
    c.glfwGetFramebufferSize(window, &reg.framebuffer_width, &reg.framebuffer_height);
    reg.size = math3d.vec2(f32(reg.framebuffer_width), f32(reg.framebuffer_height));

    c.glClearColor(0.0, 0.0, 0.0, 1.0);
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);

    c.glViewport(0, 0, reg.framebuffer_width, reg.framebuffer_height);
    c.glfwSetWindowUserPointer(window, (&c_void)(reg));

    all_shaders.createAllShaders(&reg.shaders);
    defer reg.shaders.destroy();

    reg.static_geometry = static_geometry.createStaticGeometry();
    defer reg.static_geometry.destroy();

    resetProjection(reg);

    resetMap(reg, &day_map);

    debug_gl.assertNoError();

    while (c.glfwWindowShouldClose(window) == c.GL_FALSE) {
        c.glClear(c.GL_COLOR_BUFFER_BIT|c.GL_DEPTH_BUFFER_BIT|c.GL_STENCIL_BUFFER_BIT);
        nextFrame(reg);
        drawState(reg);
        c.glfwSwapBuffers(window);
        c.glfwPollEvents();
    }

    debug_gl.assertNoError();

    return 0;
}

fn nextFrame(reg: &Regicide) {
    for (reg.players) |*player| {
        player.hitbox.center = euclideanModVec2(player.hitbox.center.plus(player.vel), reg.size);

        player.vel.data[1] += gravity_accel * spf;

        if (player.pressing(Input.Left) && !player.pressing(Input.Right)) {
            player.vel.data[0] -= move_accel * spf;
        } else if (player.pressing(Input.Right) && !player.pressing(Input.Left)) {
            player.vel.data[0] += move_accel * spf;
        }

        if (player.vel.data[1] > y_vel_max) {
            player.vel.data[1] = y_vel_max;
        }
        if (player.vel.data[0] > x_vel_max) {
            player.vel.data[0] = x_vel_max;
        }
        if (player.vel.data[0] < x_vel_min) {
            player.vel.data[0] = x_vel_min;
        }

        player.inputs_last = player.inputs;
    }
}

fn drawState(reg: &Regicide) {
    fillGradient(reg, &reg.cur_map.bg_top_color, &reg.cur_map.bg_bottom_color, 0, 0, reg.size.x(), reg.size.y());

    if (debug_draw_platforms) {
        for (reg.cur_map.platforms) |*platform| {
            drawPillShape(reg, &debug_platform_color, &platform.hitbox);
        }
    }

    for (reg.players) |*player| {
        drawPillShape(reg, &debug_player_color, &player.hitbox);
    }
}

fn fillGradientMvp(reg: &Regicide, top_color: &const Vec4, bottom_color: &const Vec4, mvp: &const Mat4x4) {
    reg.shaders.gradient.bind();
    reg.shaders.gradient.setUniformVec4(reg.shaders.gradient_uniform_color_top, top_color);
    reg.shaders.gradient.setUniformVec4(reg.shaders.gradient_uniform_color_bottom, bottom_color);
    reg.shaders.gradient.setUniformMat4x4(reg.shaders.gradient_uniform_mvp, mvp);

    c.glBindBuffer(c.GL_ARRAY_BUFFER, reg.static_geometry.rect_2d_vertex_buffer);
    c.glEnableVertexAttribArray(c.GLuint(reg.shaders.gradient_attrib_position));
    c.glVertexAttribPointer(c.GLuint(reg.shaders.gradient_attrib_position), 3, c.GL_FLOAT, c.GL_FALSE, 0, null);

    c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
}

fn fillGradient(reg: &Regicide, top_color: &const Vec4, bottom_color: &const Vec4,
    x: f32, y: f32, w: f32, h: f32)
{
    const model = math3d.mat4x4_identity.translate(x, y, 0.0).scale(w, h, 0.0);
    const mvp = reg.projection.mult(model);
    fillGradientMvp(reg, top_color, bottom_color, &mvp)
}

fn fillRectWrap(reg: &Regicide, color: &const Vec4, x: f32, y: f32, w: f32, h: f32) {
    fillRect(reg, color, x, y, w, h);
    if (x + w >= reg.size.x()) {
        fillRect(reg, color, x - reg.size.x(), y, w, h);
    }
    if (y + h >= reg.size.y()) {
        fillRect(reg, color, x, y - reg.size.y(), w, h);
    }
}

fn fillRect(reg: &Regicide, color: &const Vec4, x: f32, y: f32, w: f32, h: f32) {
    fillGradient(reg, color, color, x, y, w, h)
}

fn fillRectMvp(reg: &Regicide, color: &const Vec4, mvp: &const Mat4x4) {
    fillGradientMvp(reg, color, color, mvp)
}

fn drawPillShape(reg: &Regicide, color: &const Vec4, pill_shape: &const PillShape) {
    fillRectWrap(reg, color,
        pill_shape.center.x() - pill_shape.edge_dist.x(),
        pill_shape.center.y() - pill_shape.edge_dist.y(),
        pill_shape.edge_dist.x() * 2,
        pill_shape.edge_dist.y() * 2);
}

fn resetProjection(reg: &Regicide) {
    reg.projection = math3d.mat4x4_ortho(0.0, reg.size.x(), reg.size.y(), 0.0);
}

fn resetMap(reg: &Regicide, map: &const KqMap) {
    reg.cur_map = *map;

    for (reg.players) |*player| {
        *player = Player {
            .alive = true,
            .kind = PlayerKind.Queen,
            .hitbox = PillShape {
                .center = math3d.vec2(200.0, 200.0),
                .edge_dist = player_kind_sizes[usize(player.kind)],
            },
            .vel = math3d.vec2(0.0, 0.0),
            .inputs = inputs_reset,
            .inputs_last = inputs_reset,
        };
    }
}

fn playerInput(player: &Player, input: Input, down: bool) {
    player.inputs[usize(input)] = down;

    if (input == Input.Jump && down) {
        player.vel.setY(player.vel.y() - flap_power);
    }
}

fn euclideanMod(x: f32, base: f32) -> f32 {
    if (x < 0) {
        (x % base + base) % base
    } else {
        x % base
    }
}

fn euclideanModVec2(a: Vec2, b: Vec2) -> Vec2 {
    math3d.vec2(euclideanMod(a.x(), b.x()), euclideanMod(a.y(), b.y()))
}
