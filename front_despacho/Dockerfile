# Etapa 1: Compilación (Build)
FROM node:18-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
# Construye la aplicación estática
RUN npm run build

# Etapa 2: Producción (Servidor Nginx)
FROM nginx:alpine
# Copia los archivos estáticos generados al servidor web
COPY --from=build /app/dist /usr/share/nginx/html
# Exponemos el puerto 80
EXPOSE 80
# Arrancamos Nginx
CMD ["nginx", "-g", "daemon off;"]