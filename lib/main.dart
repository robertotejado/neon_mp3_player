// ==========================================
// IMPORTACIONES (Las herramientas que usamos)
// ==========================================
import 'package:flutter/material.dart'; // La librería base de Flutter para dibujar botones, textos, etc.
import 'package:flutter/services.dart'; // Para hablar con el sistema (ej. cerrar la app).
import 'dart:math' as math; // Para hacer cálculos matemáticos (lo usamos en la animación de flotar).
import 'dart:io'; // Para manejar archivos reales (File) del teléfono.
import 'package:file_picker/file_picker.dart'; // Para abrir el explorador de archivos de Android.
import 'package:just_audio/just_audio.dart'; // El motor de audio profesional.
import 'package:permission_handler/permission_handler.dart'; // Para pedir permisos al usuario.
import 'package:wakelock_plus/wakelock_plus.dart'; // Para mantener la pantalla siempre encendida.
import 'package:marquee/marquee.dart'; // Para el efecto de texto deslizante (marquesina).

// ==========================================
// ARRANQUE DE LA APP
// ==========================================
void main() {
  // Asegura que el motor gráfico de Flutter está listo antes de hacer nada con el sistema nativo.
  WidgetsFlutterBinding.ensureInitialized();
  WakelockPlus.enable(); // Activa el "modo vigilia" para que la pantalla no se apague en el coche.
  runApp(const NeonPlayerApp()); // Arranca la interfaz visual.
}

class NeonPlayerApp extends StatelessWidget {
  const NeonPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false, // Quita la etiqueta roja de "DEBUG" de la esquina.
      theme: ThemeData.dark(), // Forzamos el modo oscuro por defecto.
      home: const NeonPlayerScreen(), // Cargamos nuestra pantalla principal.
    );
  }
}

// ==========================================
// PANTALLA PRINCIPAL (StatefulWidget porque cambia)
// ==========================================
class NeonPlayerScreen extends StatefulWidget {
  const NeonPlayerScreen({super.key});

  @override
  State<NeonPlayerScreen> createState() => _NeonPlayerScreenState();
}

class _NeonPlayerScreenState extends State<NeonPlayerScreen> with SingleTickerProviderStateMixin {
  // VARIABLES DEL SISTEMA VISUAL Y DE AUDIO
  late AnimationController _controller; // Controla el rebote antigravedad del reproductor.
  late AudioPlayer _audioPlayer; // Nuestro motor de música.

  // Efectos de hardware de Android
  final AndroidEqualizer _equalizer = AndroidEqualizer();
  final AndroidLoudnessEnhancer _loudnessEnhancer = AndroidLoudnessEnhancer();

  final ScrollController _scrollController = ScrollController(); // El motorcito que mueve la lista sola.

  // VARIABLES DE ESTADO (La "memoria" de la app en este momento)
  List<File> playlist = []; // Guarda la lista de archivos de audio.
  int currentIndex = -1; // Por qué número de canción vamos (-1 significa ninguna).
  bool isPlaying = false; // ¿Está sonando algo?
  double volume = 1.0; // Volumen actual (de 0.0 a 1.0).

  Duration _duration = Duration.zero; // Lo que dura la canción actual.
  Duration _position = Duration.zero; // Por el segundo que vamos.

  List<double> masterBands = [0.0, 0.0, 0.0, 0.0, 0.0]; // Memoria de los niveles del ecualizador.
  String currentEqStyle = "NORMAL"; // Memoria del estilo visual del ecualizador.

  // ==========================================
  // INIT STATE (Se ejecuta UNA VEZ al arrancar la app)
  // ==========================================
  @override
  void initState() {
    super.initState();
    // 1. Configuramos la animación de flotar (Dura 3 seg y va de ida y vuelta)
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);

    // 2. Conectamos los efectos (EQ y Volumen) a la "tubería" del motor de audio
    _audioPlayer = AudioPlayer(
      audioPipeline: AudioPipeline(androidAudioEffects: [
        _equalizer,
        _loudnessEnhancer
      ]),
    );
    _equalizer.setEnabled(true);
    _loudnessEnhancer.setEnabled(true);

    // 3. OYENTES (Listeners): Están siempre atentos a lo que hace el motor de audio
    _audioPlayer.playerStateStream.listen((state) {
      if (mounted) setState(() { isPlaying = state.playing; });

      // Si la canción termina (completed), pasamos a la siguiente. Si es la última, paramos.
      if (state.processingState == ProcessingState.completed) {
        if (currentIndex < playlist.length - 1) {
          _playSong(currentIndex + 1);
        } else {
          _audioPlayer.stop();
          _audioPlayer.seek(Duration.zero);
        }
      }
    });

    // Escucha cuánto dura la pista nueva
    _audioPlayer.durationStream.listen((newDuration) {
      setState(() { _duration = newDuration ?? Duration.zero; });
    });

    // Escucha por qué segundo vamos (para mover la barra de progreso)
    _audioPlayer.positionStream.listen((newPosition) {
      setState(() { _position = newPosition; });
    });
  }

  // DISPOSE: Limpieza de memoria cuando cerramos la app para no gastar RAM.
  @override
  void dispose() {
    _controller.dispose();
    _audioPlayer.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ==========================================
  // FUNCIONES DE LÓGICA Y AUDIO
  // ==========================================

  // Convierte los segundos brutos a formato bonito (ej. "03:45")
  String formatTime(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return "$minutes:$seconds";
  }

  // Limpia el nombre del archivo: quita la extensión (.mp3, .wav)
  String _getCleanName(String path) {
    String fileName = path.split('/').last; // Coge solo el nombre, quitando carpetas.
    int lastDot = fileName.lastIndexOf('.');
    if (lastDot != -1) {
      return fileName.substring(0, lastDot); // Recorta todo lo que hay antes del punto.
    }
    return fileName;
  }

  // Abre el explorador, pide permisos y lee la música
  Future<void> pickFolder() async {
    if (await Permission.manageExternalStorage.isDenied) {
      await Permission.manageExternalStorage.request();
    }
    try {
      String? folderPath = await FilePicker.platform.getDirectoryPath();
      if (folderPath != null) {
        Directory dir = Directory(folderPath);
        // Filtra para coger solo archivos de audio.
        List<File> audioFiles = dir.listSync().whereType<File>().where((file) {
          String path = file.path.toLowerCase();
          return path.endsWith('.mp3') || path.endsWith('.wav') || path.endsWith('.flac');
        }).toList();

        // ORDENA LOS ARCHIVOS (Primero por números si los tienen, luego alfabeto A-Z)
        audioFiles.sort((a, b) {
          String nameA = a.path.split('/').last.toLowerCase();
          String nameB = b.path.split('/').last.toLowerCase();
          final regExp = RegExp(r'(\d+)');
          final matchA = regExp.firstMatch(nameA);
          final matchB = regExp.firstMatch(nameB);
          if (matchA != null && matchB != null) {
            int numA = int.parse(matchA.group(0)!);
            int numB = int.parse(matchB.group(0)!);
            if (numA != numB) return numA.compareTo(numB);
          }
          return nameA.compareTo(nameB);
        });

        // Guarda la lista ordenada y reproduce la pista 0
        setState(() { playlist = audioFiles; });
        if (playlist.isNotEmpty) {
          _playSong(0);
        }
      }
    } catch (e) {
      debugPrint("Error: $e");
    }
  }

  // Lanza una canción y hace scroll en la lista
  Future<void> _playSong(int index) async {
    setState(() { currentIndex = index; });

    // Mueve la lista visualmente a la canción correcta multiplicando por el alto del botón (56px)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        double offset = index * 56.0;
        _scrollController.animateTo(
          offset.clamp(0.0, _scrollController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
        );
      }
    });

    try {
      await _audioPlayer.setFilePath(playlist[index].path);
      await _audioPlayer.play();
    } catch (e) {
      debugPrint("Error: $e");
    }
  }

  // Play/Pausa
  Future<void> _togglePlayPause() async {
    if (playlist.isEmpty) return;
    if (_audioPlayer.playing) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play();
    }
  }

  // Aplica los cambios en la tarjeta de sonido del móvil
  Future<void> _applyEqualizerSettings(List<double> newBands, String newStyle) async {
    setState(() {
      masterBands = newBands;
      currentEqStyle = newStyle;
    });

    // Inyecta las frecuencias de los sliders
    final parameters = await _equalizer.parameters;
    for (int i = 0; i < 5 && i < parameters.bands.length; i++) {
      parameters.bands[i].setGain(newBands[i]);
    }

    // Le da un empujón de decibelios si elegimos ROCK o POP
    if (newStyle == "ROCK" || newStyle == "POP") {
      await _loudnessEnhancer.setTargetGain(0.2);
    } else {
      await _loudnessEnhancer.setTargetGain(0.0);
    }
  }

  // Abre el popup flotante del Ecualizador
  void _showEqualizer(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return NeonEqualizer(
          initialBands: List.from(masterBands),
          initialStyle: currentEqStyle,
          onEqualizerChanged: _applyEqualizerSettings,
        );
      },
    );
  }

  // ==========================================
  // CONSTRUCCIÓN VISUAL DE LA APP (UI)
  // ==========================================

  // Dibuja la cuadrícula rosa de fondo
  Widget buildBackgroundGrid() {
    return Positioned.fill(
      child: CustomPaint(painter: GridPainter()),
    );
  }

  // Dibuja un botón de neón personalizado (caja negra con reborde brillante)
  Widget neonButton(IconData icon, Color color, double size, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: color, width: 2),
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 15, spreadRadius: 1),
          ],
        ),
        child: Icon(icon, color: color, size: size * 0.6),
      ),
    );
  }

  Widget buildMainUI() {
    return Stack(
      children: [
        Row(
          children: [
            // PANEL IZQUIERDO: Explorador y Lista de Canciones
            Expanded(
              flex: 4,
              child: Container(
                margin: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  border: Border.all(color: Colors.pinkAccent, width: 1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.pinkAccent.withValues(alpha: 0.2),
                          side: const BorderSide(color: Colors.pinkAccent),
                        ),
                        onPressed: pickFolder,
                        icon: const Icon(Icons.folder, color: Colors.cyanAccent),
                        label: const Text("CARGAR CARPETA 80s", style: TextStyle(color: Colors.white)),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: _scrollController,
                        itemCount: playlist.length,
                        itemBuilder: (context, index) {
                          String cleanName = _getCleanName(playlist[index].path);
                          bool isSelected = index == currentIndex;
                          return ListTile(
                            leading: Icon(Icons.music_note, color: isSelected ? Colors.cyanAccent : Colors.grey),
                            title: Text(cleanName, style: TextStyle(
                              color: isSelected ? Colors.cyanAccent : Colors.white,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            )),
                            onTap: () => _playSong(index),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // PANEL DERECHO: Reproducto Antigravedad
            Expanded(
              flex: 5,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  // Calcula el movimiento vertical usando trigonometría (Seno)
                  double offset = math.sin(_controller.value * math.pi) * 10;
                  String currentTitle = currentIndex >= 0 ? _getCleanName(playlist[currentIndex].path) : "SIN CARGA";

                  return Transform.translate(
                    offset: Offset(0, offset),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text("NOW PLAYING", style: TextStyle(color: Colors.cyanAccent, letterSpacing: 5)),
                        const SizedBox(height: 10),

                        // TEXTO DESLIZANTE (MARQUESINA)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: SizedBox(
                            height: 40,
                            child: Marquee(
                              text: currentTitle,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 30,
                                  fontWeight: FontWeight.bold,
                                  shadows: [Shadow(color: Colors.pinkAccent, blurRadius: 15)]
                              ),
                              scrollAxis: Axis.horizontal,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              blankSpace: 100.0,
                              velocity: 40.0,
                              pauseAfterRound: const Duration(seconds: 2),
                              fadingEdgeStartFraction: 0.1,
                              fadingEdgeEndFraction: 0.1,
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),

                        // BARRA DE PROGRESO DE LA CANCIÓN
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 40),
                          child: Column(
                            children: [
                              SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14.0),
                                  trackHeight: 2.0,
                                ),
                                child: Slider(
                                  min: 0,
                                  max: _duration.inSeconds.toDouble() > 0 ? _duration.inSeconds.toDouble() : 1.0,
                                  value: _position.inSeconds.toDouble().clamp(0.0, _duration.inSeconds.toDouble() > 0 ? _duration.inSeconds.toDouble() : 1.0),
                                  activeColor: Colors.cyanAccent,
                                  inactiveColor: Colors.grey.withValues(alpha: 0.3),
                                  onChanged: (value) async {
                                    // Cambia la posición de la pista si mueves la barra
                                    final position = Duration(seconds: value.toInt());
                                    await _audioPlayer.seek(position);
                                  },
                                ),
                              ),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(formatTime(_position), style: const TextStyle(color: Colors.cyanAccent, fontSize: 12)),
                                  Text(formatTime(_duration), style: const TextStyle(color: Colors.pinkAccent, fontSize: 12)),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),

                        // BOTONERA PRINCIPAL (Prev, Play/Pause, Next)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            neonButton(Icons.skip_previous, Colors.pinkAccent, 60, () {
                              if (currentIndex > 0) _playSong(currentIndex - 1);
                            }),
                            const SizedBox(width: 20),
                            neonButton(isPlaying ? Icons.pause : Icons.play_arrow, Colors.cyanAccent, 90, _togglePlayPause),
                            const SizedBox(width: 20),
                            neonButton(Icons.skip_next, Colors.pinkAccent, 60, () {
                              if (currentIndex < playlist.length - 1) _playSong(currentIndex + 1);
                            }),
                          ],
                        ),
                        const SizedBox(height: 30),

                        // CONTROLES DE VOLUMEN Y ECUALIZADOR AMARILLO
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.volume_down, color: Colors.cyanAccent),
                            Slider(
                              value: volume,
                              min: 0.0,
                              max: 1.0,
                              activeColor: Colors.pinkAccent,
                              inactiveColor: Colors.grey,
                              onChanged: (val) {
                                setState(() { volume = val; });
                                _audioPlayer.setVolume(volume);
                              },
                            ),
                            const Icon(Icons.volume_up, color: Colors.pinkAccent),
                            const SizedBox(width: 20),
                            neonButton(Icons.equalizer, Colors.yellowAccent, 50, () => _showEqualizer(context)),
                          ],
                        )
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),

        // BOTÓN DE APAGADO (SystemNavigator.pop cierra la app forzosamente)
        Positioned(
          top: 30,
          right: 80,
          child: Container(
            decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.redAccent, width: 2),
                boxShadow: [
                  BoxShadow(color: Colors.redAccent.withValues(alpha: 0.4), blurRadius: 15)
                ]
            ),
            child: IconButton(
              icon: const Icon(Icons.power_settings_new, color: Colors.redAccent, size: 35),
              onPressed: () {
                SystemNavigator.pop();
              },
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          buildBackgroundGrid(), // La capa del fondo
          buildMainUI(),         // La capa de la interfaz encima
        ],
      ),
    );
  }
}

// ==========================================
// CLASE DEL ECUALIZADOR (Pantalla Flotante / Dialog)
// ==========================================
class NeonEqualizer extends StatefulWidget {
  final List<double> initialBands;
  final String initialStyle;
  final Function(List<double>, String) onEqualizerChanged;

  const NeonEqualizer({
    super.key,
    required this.initialBands,
    required this.initialStyle,
    required this.onEqualizerChanged
  });

  @override
  State<NeonEqualizer> createState() => _NeonEqualizerState();
}

class _NeonEqualizerState extends State<NeonEqualizer> {
  late List<double> bands;
  late String currentStyle;

  @override
  void initState() {
    super.initState();
    bands = List.from(widget.initialBands); // Recupera la memoria de los niveles
    currentStyle = widget.initialStyle; // Recupera el texto pulsado
  }

  // Lógica de los presets de sonido
  void setStyle(String style) {
    setState(() {
      currentStyle = style;
      if (style == "POP") {
        bands = [1.5, 3.0, 4.0, 2.0, -1.0];
      } else if (style == "ROCK") {
        bands = [5.0, 3.0, -1.0, 3.0, 5.0];
      } else if (style == "JAZZ") {
        bands = [3.0, 2.0, -2.0, 2.0, 4.0];
      } else if (style == "NORMAL") {
        bands = [0.0, 0.0, 0.0, 0.0, 0.0];
      }
      widget.onEqualizerChanged(bands, currentStyle); // Envía los datos a la App principal
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent, // Fondo transparente para que el Container haga los bordes
      child: Stack(
        clipBehavior: Clip.none, // Permite que la X roja sobresalga de la caja
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.95), // Casi negro sólido para tapar lo de atrás
              border: Border.all(color: Colors.cyanAccent, width: 2),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(color: Colors.cyanAccent.withValues(alpha: 0.3), blurRadius: 20, spreadRadius: 5)
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("E Q U A L I Z E R", style: TextStyle(color: Colors.white, fontSize: 18, letterSpacing: 5, fontWeight: FontWeight.bold, shadows: [Shadow(color: Colors.pinkAccent, blurRadius: 10)])),
                const SizedBox(height: 15),

                // Botonera de Estilos (Mapea la lista y crea botones)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: ["NORMAL", "POP", "ROCK", "JAZZ"].map((style) {
                    bool isActive = currentStyle == style; // Si coincide, lo pinta de rosa
                    return GestureDetector(
                      onTap: () => setStyle(style),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: isActive ? Colors.pinkAccent.withValues(alpha: 0.3) : Colors.transparent,
                          border: Border.all(color: isActive ? Colors.pinkAccent : Colors.grey),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(style, style: TextStyle(color: isActive ? Colors.pinkAccent : Colors.grey, fontSize: 12)),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 25),

                // Generador de las 5 barras verticales
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: List.generate(5, (index) {
                    return Column(
                      children: [
                        // Etiqueta superior del decibelio (+3, -1)
                        Text("${bands[index] > 0 ? '+' : ''}${bands[index].toInt()}", style: const TextStyle(color: Colors.cyanAccent, fontSize: 12)),
                        const SizedBox(height: 10),
                        RotatedBox(
                          quarterTurns: 3, // Gira el slider horizontal 270 grados
                          child: SizedBox(
                            width: 130, // Limita el tamaño para que no reviente el popup
                            child: Slider(
                              value: bands[index],
                              min: -10.0,
                              max: 10.0,
                              activeColor: Colors.pinkAccent,
                              inactiveColor: Colors.grey.withValues(alpha: 0.3),
                              onChanged: (val) {
                                setState(() {
                                  bands[index] = val;
                                  currentStyle = "CUSTOM"; // Si lo tocas manual, quita el modo ROCK/POP
                                });
                                widget.onEqualizerChanged(bands, currentStyle);
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        // Etiqueta de la frecuencia (Graves a la izq, Agudos a la der)
                        Text(["60", "230", "910", "3.6K", "14K"][index], style: const TextStyle(color: Colors.grey, fontSize: 12)),
                      ],
                    );
                  }),
                ),
              ],
            ),
          ),

          // La famosa X roja para cerrar el popup
          Positioned(
            top: -15,
            right: -15,
            child: GestureDetector(
              onTap: () => Navigator.pop(context), // El "pop" destruye la pantalla actual (el Dialog)
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.black,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.cancel, color: Colors.redAccent, size: 35),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// PINTOR DEL FONDO (El artista de la cuadrícula)
// ==========================================
class GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Definimos la "brocha"
    final paint = Paint()
      ..color = Colors.pinkAccent.withValues(alpha: 0.2)
      ..strokeWidth = 1.0;

    // Pintamos líneas horizontales
    for (double i = 0; i < size.height; i += 40) {
      canvas.drawLine(Offset(0, i), Offset(size.width, i), paint);
    }
    // Pintamos líneas convergentes simulando un camino hacia el horizonte 3D
    for (double i = 0; i < size.width; i += 80) {
      canvas.drawLine(Offset(i, size.height), Offset(size.width / 2, size.height / 2.5), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false; // Nunca redibujar, ahorra batería
}