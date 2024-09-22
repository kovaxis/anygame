function love.keypressed(key)
    if key == 'escape' then
        love.event.quit()
    end
end

function love.draw()
    love.graphics.clear(1, 0, 0)
    love.graphics.print("juego de prueba", 0, 0)
end