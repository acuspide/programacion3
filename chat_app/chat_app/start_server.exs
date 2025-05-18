# Script para iniciar el servidor de chat
# Ejecutar con: elixir start_server.exs

# Asegurar que todas las dependencias estén compiladas
Mix.ensure_application!(:chat_app)

# Código para iniciar el servidor
code = """
defmodule StartServer do
  def run do
    # Obtener la IP local
    {_, interfaces} = :inet.getif()
    ip = case Enum.find(interfaces, fn {ip, _, _} ->
      ip_string = :inet.ntoa(ip) |> to_string()
      not String.starts_with?(ip_string, "127.") and not String.starts_with?(ip_string, "169.254.")
    end) do
      {ip, _, _} -> :inet.ntoa(ip) |> to_string()
      _ -> "localhost"
    end

    # Iniciar el nodo con nombre
    nombre_nodo = "chat_server@" <> ip
    Node.start(String.to_atom(nombre_nodo), :shortnames)
    Node.set_cookie(:chat_secret)

    IO.puts("\\nServidor de chat iniciado en nodo: \#{nombre_nodo}")
    IO.puts("IP del servidor: \#{ip}")
    IO.puts("Cookie: chat_secret")

    # Crear el directorio para datos
    File.mkdir_p!("datos_chat")

    # Iniciar el servidor de chat
    {:ok, _} = ChatServer.iniciar()

    IO.puts("\\nServidor listo para aceptar conexiones.")
    IO.puts("Los clientes pueden conectarse usando: mix run start_client.exs \#{ip}")
    IO.puts("\\nPresiona Ctrl+C dos veces para detener el servidor.")

    # Mantener el script en ejecución
    :timer.sleep(:infinity)
  end
end

StartServer.run()
"""

# Escribir el script a un archivo temporal
path = Path.join(System.tmp_dir!(), "start_server_temp.exs")
File.write!(path, code)

# Ejecutar el script con el entorno de Mix
System.cmd("elixir", ["-S", "mix", "run", path], into: IO.stream(:stdio, :line))
