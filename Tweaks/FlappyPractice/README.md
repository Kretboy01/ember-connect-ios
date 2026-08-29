# FlappyPractice

An advanced practice and modification tweak for Brandon Plank's Flappy Bird (org.brandonplank.flappybird). Injected via LiveContainer's TweakLoader.

## Features

### Floating Panel UI
- **Draggable floating button**: Accessible anywhere on screen via a pan gesture.
- **Settings Panel**: Expanding visual effect view organized into distinct settings categories with smooth slide animations.

### Physics & Speed
- **Speed Slider (0.25x - 2.0x)**: Change the speed of the game scene dynamically.
- **Gravity Slider (0.25x - 3.0x)**: Independent control over the physics world gravity.
- **Flap Power (0.5x - 3.0x)**: Modifies the bird's jump impulse.

### Gameplay Mods
- **Wide Gaps**: Increases the vertical distance between top and bottom pipes.
- **Ghost Mode (No Clip)**: Disables physics collisions for the bird.
- **Auto-Pilot**: Automatically flaps when the bird drops below a safe threshold.
- **Instant Restart**: Triggers a fast restart upon failure.
- **Score Multiplier**: Scales your displayed score dynamically.

### Visual Effects
- **Night Mode**: Darkens the environment to simulate nighttime.
- **Bird Trail**: Emits fiery particles from the bird.
- **Pipe Tint**: Blends pipes with a custom purple color.
- **Hitbox Visualizer**: Renders debug outlines over all physics bodies.

### Stats HUD
- On-screen overlay presenting frames per second (FPS), current modifiers, games played, and best session score. Updates twice a second.

### Profiles
- Save, Load, and switch between standard presets: **Easy**, **Speed Run**, and **Practice**.
