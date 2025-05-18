defp send_message_to_client(pid, node, message) do
  try do
    # Verificar si el nodo está vivo antes de intentar enviar
    node_status = Node.ping(node)

    if node_status == :pong do
      # El nodo está vivo, intentar enviar el mensaje
      :erlang.send({pid, node}, message)
      :ok
    else
      # El nodo no está disponible
      Logger.warning("No se puede enviar mensaje: nodo #{node} no disponible")
      :error
    end
  rescue
    e ->
      Logger.warning("Error al enviar mensaje: #{inspect(e)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("Error (exit) al enviar mensaje: #{inspect(reason)}")
      :error
    _, reason ->
      Logger.warning("Error inesperado al enviar mensaje: #{inspect(reason)}")
      :error
  end
end

@impl true
def handle_cast({:enviar_mensaje, username, nombre_sala, mensaje}, estado) do
  Logger.debug("Mensaje en #{nombre_sala} de #{username}: #{mensaje}")

  # Verificar si la sala existe
  if not Map.has_key?(estado.salas, nombre_sala) do
    {:noreply, estado}
  else
    sala = estado.salas[nombre_sala]

    # Verificar si el usuario está en la sala
    nuevo_estado = if username not in sala.miembros do
      # Si el usuario no está en la sala, añadirlo automáticamente
      miembros_actualizados = [username | sala.miembros]
      sala_actualizada = %{sala | miembros: miembros_actualizados}
      nuevas_salas = Map.put(estado.salas, nombre_sala, sala_actualizada)
      %{estado | salas: nuevas_salas}
    else
      estado
    end

    # Guardar el mensaje
    timestamp = :os.system_time(:millisecond)
    mensajes_sala = if Map.has_key?(nuevo_estado.mensajes, nombre_sala) do
      [{username, mensaje, timestamp} | nuevo_estado.mensajes[nombre_sala]]
    else
      [{username, mensaje, timestamp}]
    end

    nuevos_mensajes = Map.put(nuevo_estado.mensajes, nombre_sala, mensajes_sala)

    # Actualizar estado
    nuevo_estado = %{nuevo_estado | mensajes: nuevos_mensajes}

    # Persistir mensajes
    guardar_mensajes_en_archivo(nuevo_estado.mensajes)

    # Enviar mensaje a todos los miembros de la sala, incluido el remitente
    sala = nuevo_estado.salas[nombre_sala]

    # Mensaje formateado para el chat
    mensaje_formateado = {:mensaje_chat, nombre_sala, username, mensaje, timestamp}

    # Lista para almacenar usuarios a los que no se pudo enviar
    usuarios_sin_entrega = []

    usuarios_sin_entrega = Enum.reduce(sala.miembros, usuarios_sin_entrega, fn miembro, acc ->
      case Map.get(nuevo_estado.usuarios_conectados, miembro) do
        {pid, nodo} ->
          case send_message_to_client(pid, nodo, mensaje_formateado) do
            :ok -> acc
            :error -> [miembro | acc]
          end
        _ ->
          [miembro | acc]
      end
    end)

    # Si hay usuarios a los que no se pudo entregar, log informativo
    unless Enum.empty?(usuarios_sin_entrega) do
      Logger.info("Mensaje no entregado a algunos usuarios: #{inspect(usuarios_sin_entrega)}")
    end

    {:noreply, nuevo_estado}
  end
end
