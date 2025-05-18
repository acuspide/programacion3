defmodule ChatServer do
  @moduledoc """
  Módulo que implementa el servidor de chat.
  Gestiona usuarios, salas y mensajes.
  """
  use GenServer
  require Logger

  # Nombre global para el registro del servidor
  @nombre_servidor :chat_servidor

  # Archivos para persistencia
  @archivo_mensajes "datos_chat/historial_mensajes.dat"
  @archivo_salas "datos_chat/salas.dat"
  @archivo_usuarios "datos_chat/usuarios.dat"

  # API PÚBLICA

  @doc """
  Inicia el servidor de chat.
  """
  def iniciar do
    GenServer.start_link(__MODULE__, :ok, name: {:global, @nombre_servidor})
  end

  @doc """
  Registra un nuevo usuario.
  """
  def registrar_usuario(username, password, client_pid, client_node) do
    GenServer.call({:global, @nombre_servidor}, {:registrar_usuario, username, password, client_pid, client_node})
  end

  @doc """
  Autentica a un usuario.
  """
  def autenticar(username, password, client_pid, client_node) do
    GenServer.call({:global, @nombre_servidor}, {:autenticar, username, password, client_pid, client_node})
  end

  @doc """
  Da de baja a un usuario (desconexión).
  """
  def dar_baja_usuario(username) do
    GenServer.cast({:global, @nombre_servidor}, {:dar_baja, username})
  end

  @doc """
  Crea una nueva sala de chat.
  """
  def crear_sala(username, nombre_sala) do
    GenServer.call({:global, @nombre_servidor}, {:crear_sala, username, nombre_sala})
  end

  @doc """
  Une a un usuario a una sala existente.
  """
  def unirse_sala(username, nombre_sala) do
    GenServer.call({:global, @nombre_servidor}, {:unirse_sala, username, nombre_sala})
  end

  @doc """
  Envía un mensaje a una sala.
  """
  def enviar_mensaje(username, nombre_sala, mensaje) do
    GenServer.cast({:global, @nombre_servidor}, {:enviar_mensaje, username, nombre_sala, mensaje})
  end

  @doc """
  Lista los usuarios conectados.
  """
  def listar_usuarios do
    GenServer.call({:global, @nombre_servidor}, :listar_usuarios)
  end

  @doc """
  Lista las salas disponibles.
  """
  def listar_salas do
    GenServer.call({:global, @nombre_servidor}, :listar_salas)
  end

  @doc """
  Obtiene el historial de mensajes de una sala.
  """
  def obtener_historial_sala(nombre_sala) do
    GenServer.call({:global, @nombre_servidor}, {:obtener_historial, nombre_sala})
  end

  # CALLBACKS DEL GENSERVER

  @impl true
  def init(:ok) do
    Logger.info("Servidor de chat iniciado en nodo #{Node.self()}")
    Process.flag(:trap_exit, true)

    # Crear directorio para datos si no existe
    File.mkdir_p!("datos_chat")

    # Cargar datos guardados
    mensajes = cargar_mensajes_desde_archivo()
    salas = cargar_salas_desde_archivo()
    usuarios = cargar_usuarios_desde_archivo()

    # Inicializar salas si no existen
    salas = if map_size(salas) == 0 do
      %{}
    else
      salas
    end

    # Verificar que cada sala tenga una entrada en mensajes
    mensajes = Enum.reduce(Map.keys(salas), mensajes, fn nombre_sala, acc ->
      if not Map.has_key?(acc, nombre_sala) do
        Map.put(acc, nombre_sala, [])
      else
        acc
      end
    end)

    estado = %{
      usuarios_conectados: %{},  # %{username => {pid, node}}
      salas: salas,              # %{nombre_sala => %{creador: username, miembros: [username]}}
      mensajes: mensajes,        # %{nombre_sala => [{from, message, timestamp}]}
      usuarios: usuarios         # %{username => password_hash}
    }

    # Registrar en servicios globales
    :global.register_name(@nombre_servidor, self())

    {:ok, estado}
  end

  @impl true
  def handle_call({:registrar_usuario, username, password, client_pid, client_node}, _from, estado) do
    Logger.info("Registrando nuevo usuario: #{username} desde #{client_node}")

    # Verificar si el usuario ya existe
    if Map.has_key?(estado.usuarios, username) do
      {:reply, {:error, :usuario_existente}, estado}
    else
      # Hashear la contraseña
      password_hash = :crypto.hash(:sha256, password) |> Base.encode16()

      # Añadir usuario a la base de datos
      nuevos_usuarios = Map.put(estado.usuarios, username, password_hash)

      # Añadir el usuario a los conectados
      Process.monitor(client_pid)
      nuevos_conectados = Map.put(estado.usuarios_conectados, username, {client_pid, client_node})

      # Actualizar estado
      nuevo_estado = %{estado |
        usuarios: nuevos_usuarios,
        usuarios_conectados: nuevos_conectados
      }

      # Persistir cambios
      guardar_usuarios_en_archivo(nuevo_estado.usuarios)

      # Notificar a todos los usuarios conectados
      broadcast_mensaje_sistema("#{username} se ha registrado y unido al chat", nuevo_estado)

      {:reply, {:ok, username}, nuevo_estado}
    end
  end

  @impl true
  def handle_call({:autenticar, username, password, client_pid, client_node}, _from, estado) do
    Logger.info("Intentando autenticar usuario: #{username} desde #{client_node}")

    # Hashear la contraseña proporcionada
    password_hash = :crypto.hash(:sha256, password) |> Base.encode16()

    # Verificar credenciales
    if Map.has_key?(estado.usuarios, username) && estado.usuarios[username] == password_hash do
      # Monitorear el proceso cliente para detectar desconexiones
      Process.monitor(client_pid)

      # Si el usuario ya está conectado, actualizar su información
      nuevo_estado = if Map.has_key?(estado.usuarios_conectados, username) do
        # Actualizar la información de conexión
        %{estado | usuarios_conectados: Map.put(estado.usuarios_conectados, username, {client_pid, client_node})}
      else
        # Añadir el usuario a los conectados
        %{estado | usuarios_conectados: Map.put(estado.usuarios_conectados, username, {client_pid, client_node})}
      end

      broadcast_mensaje_sistema("#{username} se ha unido al chat", nuevo_estado)

      {:reply, {:ok, username}, nuevo_estado}
    else
      {:reply, {:error, :auth_fallida}, estado}
    end
  end

  @impl true
  def handle_call({:crear_sala, username, nombre_sala}, _from, estado) do
    Logger.info("Creando sala: #{nombre_sala} por usuario #{username}")

    # Verificar si la sala ya existe
    if Map.has_key?(estado.salas, nombre_sala) do
      {:reply, {:error, :sala_existente}, estado}
    else
      # Crear la sala
      sala = %{creador: username, miembros: [username]}
      nuevas_salas = Map.put(estado.salas, nombre_sala, sala)
      nuevos_mensajes = Map.put(estado.mensajes, nombre_sala, [])

      # Actualizar estado
      nuevo_estado = %{estado | salas: nuevas_salas, mensajes: nuevos_mensajes}

      # Persistir cambios
      guardar_salas_en_archivo(nuevo_estado.salas)
      guardar_mensajes_en_archivo(nuevo_estado.mensajes)

      # Notificar a todos los usuarios
      broadcast_mensaje_sistema("Nueva sala creada: #{nombre_sala}", nuevo_estado)

      {:reply, :ok, nuevo_estado}
    end
  end

  @impl true
  def handle_call({:unirse_sala, username, nombre_sala}, _from, estado) do
    Logger.info("Usuario #{username} uniéndose a sala #{nombre_sala}")

    # Verificar si la sala existe
    if not Map.has_key?(estado.salas, nombre_sala) do
      {:reply, {:error, :sala_no_encontrada}, estado}
    else
      sala = estado.salas[nombre_sala]

      # Verificar si el usuario ya está en la sala
      if username in sala.miembros do
        {:reply, :ok, estado}  # Ya está en la sala, sin error
      else
        # Añadir usuario a la sala
        miembros_actualizados = [username | sala.miembros]
        sala_actualizada = %{sala | miembros: miembros_actualizados}
        nuevas_salas = Map.put(estado.salas, nombre_sala, sala_actualizada)

        # Actualizar estado
        nuevo_estado = %{estado | salas: nuevas_salas}

        # Persistir cambios
        guardar_salas_en_archivo(nuevo_estado.salas)

        # Notificar a los miembros de la sala
        notificar_miembros_sala(nombre_sala, "#{username} se ha unido a la sala", nuevo_estado)

        {:reply, :ok, nuevo_estado}
      end
    end
  end

  @impl true
  def handle_call(:listar_usuarios, _from, estado) do
    {:reply, Map.keys(estado.usuarios_conectados), estado}
  end

  @impl true
  def handle_call(:listar_salas, _from, estado) do
    {:reply, Map.keys(estado.salas), estado}
  end

  @impl true
  def handle_call({:obtener_historial, nombre_sala}, _from, estado) do
    mensajes = if Map.has_key?(estado.mensajes, nombre_sala) do
      # Invertir para tener los mensajes en orden cronológico
      Enum.reverse(estado.mensajes[nombre_sala])
    else
      []
    end

    {:reply, mensajes, estado}
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
      Enum.each(sala.miembros, fn miembro ->
        case Map.get(nuevo_estado.usuarios_conectados, miembro) do
          {pid, _} ->
            try do
              send(pid, {:mensaje_chat, nombre_sala, username, mensaje, timestamp})
            rescue
              _ -> Logger.warning("Error al enviar mensaje a #{miembro}")
            end
          _ -> :ok
        end
      end)

      {:noreply, nuevo_estado}
    end
  end

  @impl true
  def handle_cast({:dar_baja, username}, estado) do
    Logger.info("Usuario #{username} desconectado")

    # Eliminar usuario de la lista de conectados
    {_, nuevos_conectados} = Map.pop(estado.usuarios_conectados, username)

    # No eliminar usuario de las salas para mantener el historial
    # Solo anunciar que se ha desconectado
    broadcast_mensaje_sistema("#{username} ha salido del chat", %{estado | usuarios_conectados: nuevos_conectados})

    {:noreply, %{estado | usuarios_conectados: nuevos_conectados}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, estado) do
    # Buscar el usuario correspondiente al PID caído
    username = encontrar_usuario_por_pid(pid, estado.usuarios_conectados)

    if username do
      # Usar handle_cast para manejar la baja del usuario
      handle_cast({:dar_baja, username}, estado)
    else
      {:noreply, estado}
    end
  end

  @impl true
  def terminate(_reason, estado) do
    # Guardar estado al terminar
    guardar_mensajes_en_archivo(estado.mensajes)
    guardar_salas_en_archivo(estado.salas)
    guardar_usuarios_en_archivo(estado.usuarios)
    :ok
  end

  @impl true
  def handle_info(mensaje, estado) do
    Logger.debug("Mensaje inesperado recibido en el servidor: #{inspect(mensaje)}")
    {:noreply, estado}
  end

  # FUNCIONES PRIVADAS

  # Busca un usuario por su PID
  defp encontrar_usuario_por_pid(pid, usuarios_conectados) do
    Enum.find_value(usuarios_conectados, fn {username, {client_pid, _}} ->
      if client_pid == pid, do: username, else: nil
    end)
  end

  # Envía un mensaje a todos los usuarios conectados
  defp broadcast_mensaje_sistema(mensaje, estado) do
    Enum.each(estado.usuarios_conectados, fn {_, {pid, _}} ->
      try do
        send(pid, {:mensaje_sistema, mensaje})
      rescue
        _ -> :ok  # Ignorar errores de envío
      end
    end)
  end

  # Envía un mensaje a todos los miembros de una sala
  defp notificar_miembros_sala(nombre_sala, mensaje, estado) do
    if Map.has_key?(estado.salas, nombre_sala) do
      Enum.each(estado.salas[nombre_sala].miembros, fn miembro ->
        case Map.get(estado.usuarios_conectados, miembro) do
          {pid, _} ->
            try do
              send(pid, {:mensaje_sistema, "[#{nombre_sala}] #{mensaje}"})
            rescue
              _ -> :ok  # Ignorar errores de envío
            end
          _ -> :ok
        end
      end)
    end
  end

  # Persistencia de mensajes
  defp guardar_mensajes_en_archivo(mensajes) do
    try do
      File.write!(@archivo_mensajes, :erlang.term_to_binary(mensajes))
    rescue
      e ->
        Logger.error("Error al guardar mensajes: #{inspect(e)}")
        :error
    end
  end

  defp cargar_mensajes_desde_archivo do
    try do
      case File.read(@archivo_mensajes) do
        {:ok, binary} -> :erlang.binary_to_term(binary)
        {:error, _} -> %{}  # Archivo no existe, retornar mapa vacío
      end
    rescue
      e ->
        Logger.error("Error al cargar mensajes: #{inspect(e)}")
        %{}
    end
  end

  # Persistencia de salas
  defp guardar_salas_en_archivo(salas) do
    try do
      File.write!(@archivo_salas, :erlang.term_to_binary(salas))
    rescue
      e ->
        Logger.error("Error al guardar salas: #{inspect(e)}")
        :error
    end
  end

  defp cargar_salas_desde_archivo do
    try do
      case File.read(@archivo_salas) do
        {:ok, binary} -> :erlang.binary_to_term(binary)
        {:error, _} -> %{}  # Archivo no existe, retornar mapa vacío
      end
    rescue
      e ->
        Logger.error("Error al cargar salas: #{inspect(e)}")
        %{}
    end
  end

  # Persistencia de usuarios
  defp guardar_usuarios_en_archivo(usuarios) do
    try do
      File.write!(@archivo_usuarios, :erlang.term_to_binary(usuarios))
    rescue
      e ->
        Logger.error("Error al guardar usuarios: #{inspect(e)}")
        :error
    end
  end

  defp cargar_usuarios_desde_archivo do
    try do
      case File.read(@archivo_usuarios) do
        {:ok, binary} -> :erlang.binary_to_term(binary)
        {:error, _} ->
          # Crear usuarios predeterminados
          %{
            "admin" => :crypto.hash(:sha256, "admin123") |> Base.encode16(),
            "usuario1" => :crypto.hash(:sha256, "pass123") |> Base.encode16(),
            "invitado" => :crypto.hash(:sha256, "guest123") |> Base.encode16()
          }
      end
    rescue
      e ->
        Logger.error("Error al cargar usuarios: #{inspect(e)}")
        # Usuarios predeterminados
        %{
          "admin" => :crypto.hash(:sha256, "admin123") |> Base.encode16(),
          "usuario1" => :crypto.hash(:sha256, "pass123") |> Base.encode16(),
          "invitado" => :crypto.hash(:sha256, "guest123") |> Base.encode16()
        }
    end
  end
end
