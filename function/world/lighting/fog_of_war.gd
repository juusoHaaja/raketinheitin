extends Sprite2D

const light_texture = preload("res://art/background/Light.png")
const GRID_SIZE = 16

var fog = self

var fog_image_width = 4092# / GRID_SIZE
var fog_image_height = 4092# / GRID_SIZE

var fogImage := Image.create(fog_image_width, fog_image_height, false, Image.FORMAT_RGBAH)
var fogTexture: ImageTexture
var lightImage = light_texture.get_image()
var light_offset = Vector2(light_texture.get_width()/2, light_texture.get_height()/2)

func _ready():
    fogImage.fill(Color.BLACK)
    lightImage.convert(Image.FORMAT_RGBAH)
    fog.scale *= GRID_SIZE
    fog.texture = ImageTexture.create_from_image(fogImage)


func update_fog(new_grid_position):
    
    var light_rect = Rect2i(Vector2.ZERO, Vector2(lightImage.get_width(), lightImage.get_height()))
    fogImage.blend_rect(lightImage, light_rect, new_grid_position - light_offset)
    
    update_fog_image_texture()

func update_fog_image_texture():
    fogTexture = ImageTexture.create_from_image(fogImage)
    fog.texture = fogTexture

func _unhandled_input(event):
    if event.is_pressed():
        if event.button_index == MOUSE_BUTTON_LEFT:
            update_fog(get_local_mouse_position() + Vector2(fog_image_width / 2.,fog_image_height / 2.))
